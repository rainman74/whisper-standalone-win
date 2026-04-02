import sys
import os
import re
import glob
import subprocess
import requests
import textwrap
import time
from datetime import datetime
from difflib import SequenceMatcher

OLLAMA_API = "http://127.0.0.1:11434"
MODEL      = "mistral-nemo"

# ---------------------------------------------------------------------------
#  Ollama Setup
# ---------------------------------------------------------------------------

def _server_running():
    try:
        requests.get(f"{OLLAMA_API}/api/tags", timeout=2)
        return True
    except:
        return False

def _start_server():
    print("  Starting Ollama server ...", flush=True)
    kwargs = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    if sys.platform == "win32":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    subprocess.Popen(["ollama", "serve"], **kwargs)
    for _ in range(20):
        time.sleep(1)
        if _server_running():
            return True
    print("  [ERROR] Ollama server did not respond in time.")
    return False

def _preload_model():
    # Evict first so GPU layer settings are applied fresh on reload
    try:
        requests.post(f"{OLLAMA_API}/api/generate", json={
            "model": MODEL, "prompt": "", "keep_alive": 0
        }, timeout=10)
    except:
        pass
    print(f"  Preloading [{MODEL}] ...", flush=True)
    print()
    try:
        requests.post(f"{OLLAMA_API}/api/generate", json={
            "model": MODEL,
            "prompt": "",
            "stream": False,
            "keep_alive": "999h",
            "options": {
                "num_ctx": 4096,
                "num_gpu": 99,
            }
        }, timeout=60)
    except:
        pass

def stop_ollama():
    try:
        subprocess.run(["taskkill", "/f", "/im", "ollama.exe"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except:
        pass

def setup_ollama():
    # Always restart so OLLAMA_FLASH_ATTENTION and OLLAMA_KV_CACHE_TYPE
    # (set by Transcribe.bat) are inherited by the server process.
    if _server_running():
        print("  Restarting Ollama to apply GPU memory settings ...", flush=True)
        stop_ollama()
        time.sleep(3)
    if not _start_server():
        sys.exit(1)
    _preload_model()
    result = subprocess.run(["ollama", "ps"], capture_output=True, text=True)
    if result.stdout.strip():
        print(result.stdout.strip(), flush=True)
    print(flush=True)

# ---------------------------------------------------------------------------
#  Uebersetzungslogik
# ---------------------------------------------------------------------------

def get_gap(ts_prev, ts_next):
    try:
        end_prev = ts_prev.split(' --> ')[1].strip()
        start_next = ts_next.split(' --> ')[0].strip()
        t1 = datetime.strptime(end_prev, '%H:%M:%S,%f')
        t2 = datetime.strptime(start_next, '%H:%M:%S,%f')
        return (t2 - t1).total_seconds()
    except:
        return 999

def similarity(a, b):
    return SequenceMatcher(None, a, b).ratio()

def translate_text(text, context_blocks=None, ctx=3, force_variety=False):
    if not text.strip():
        return text

    # Build context from last ctx EN+DE pairs
    context_str = ""
    if context_blocks and ctx > 0:
        for en, de in context_blocks[-ctx:]:
            context_str += f"  {en} → {de}\n"

    prompt = (
        f"[INST] Role: Professional Subtitle Translator\n"
        f"Previous translations:\n{context_str}"
        f"Translate to German: {text}\n\n"
        f"Rules:\n"
        f"1. Use sophisticated, valid German vocabulary.\n"
        f"2. Match the style and register of the previous translations.\n"
        f"3. NO notes, NO quotes, NO explanations.\n"
        f"4. Output ONLY the German translation for the 'Target'.\n"
        f"5. If Target is a fragment, do not complete it unless grammar requires it.\n"
        f"6. Be semantically precise and translate ALL information of the 'Target'.\n"
        f"7. Strictly NO explanations. Output ONLY German text. [/INST]"
    )
    payload = {
        "model": MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {
            "think": False,
            "num_ctx": 4096,
            "num_gpu": 99,
            "temperature": 0.1 if force_variety else 0.0,
            "num_predict": 256,
            "repeat_penalty": 1.1,
            "top_p": 0.5,
            "stop": ["[INST]", "[/INST]"],
        }
    }
    try:
        response = requests.post(f"{OLLAMA_API}/api/generate", json=payload, timeout=60)
        result = response.json().get('response', '').strip()
        result = result.replace('"', '').replace('\u201e', '').replace('\u201c', '').strip()
        # Fallback to original text if model returned nothing
        return result if result else text
    except Exception as e:
        print(f"\n  [WARNING] Translation failed: {e}", flush=True)
        return text

def split_translation(text):
    if not text: return "", ""
    delimiters = [". ", "! ", "? ", "; ", ", "]
    best_split = -1
    mid_point = len(text) // 2
    for d in delimiters:
        idx = text.find(d)
        while idx != -1:
            diff = abs((idx + len(d)) - mid_point)
            if diff < (len(text) * 0.4):
                best_split = idx + len(d)
            idx = text.find(d, idx + 1)
    if best_split != -1:
        return text[:best_split].strip(), text[best_split:].strip()
    words = text.split()
    mid = len(words) // 2
    return " ".join(words[:mid]), " ".join(words[mid:])

def cleanup_wavs(input_file):
    srt_dir = os.path.dirname(input_file)
    srt_stem = os.path.splitext(os.path.basename(input_file))[0]
    if srt_stem.upper().endswith(".EN"):
        srt_stem = srt_stem[:-3]
    for f in glob.glob(os.path.join(srt_dir, srt_stem + "*.wav")):
        try:
            os.remove(f)
        except:
            pass

def write_srt(path, header, translated_blocks):
    with open(path, 'w', encoding='utf-8') as f:
        f.write(header)
        for i, (ts, text) in enumerate(translated_blocks, 1):
            wrapped_text = textwrap.fill(text, width=45, break_long_words=False)
            ts_line = ts.strip().splitlines()[-1]
            f.write(f"{i}\n{ts_line}\n{wrapped_text}\n\n")

def process_srt(input_file, output_file, ctx=3):
    start_timer = time.time()
    with open(input_file, 'r', encoding='utf-8') as f:
        content = f.read()
    parts = re.split(r'(\d+\n\d{2}:\d{2}:\d{2},\d{3} --> \d{2}:\d{2}:\d{2},\d{3})', content)
    header = parts[0]
    blocks = []
    for i in range(1, len(parts), 2):
        blocks.append({"timestamp": parts[i], "text": parts[i+1].strip()})
    total_blocks = len(blocks)
    translated_blocks = []
    context_blocks = []
    skip_next = False
    try:
        for i in range(total_blocks):
            print(f"\r{i+1} of {total_blocks} subtitles translated", end="", flush=True)
            if skip_next:
                skip_next = False
                continue
            current_en = blocks[i]["text"]
            if i < len(blocks) - 1 and not re.search(r'[.!?]$', current_en):
                gap = get_gap(blocks[i]["timestamp"], blocks[i+1]["timestamp"])
                if gap < 0.3:
                    next_en = blocks[i+1]["text"]
                    combined_en = current_en + " " + next_en
                    full_translation = translate_text(combined_en, context_blocks, ctx)
                    part1, part2 = split_translation(full_translation)
                    translated_blocks.append((blocks[i]["timestamp"], part1))
                    translated_blocks.append((blocks[i+1]["timestamp"], part2))
                    context_blocks.append((current_en, part1))
                    context_blocks.append((next_en, part2))
                    skip_next = True
                    continue
            translation = translate_text(current_en, context_blocks, ctx)
            if translated_blocks and similarity(translation, translated_blocks[-1][1]) > 0.8:
                translation = translate_text(current_en, context_blocks, ctx, force_variety=True)
            translated_blocks.append((blocks[i]["timestamp"], translation))
            context_blocks.append((current_en, translation))

    except KeyboardInterrupt:
        print(f"\n\n  [CANCELLED] {len(translated_blocks)} of {total_blocks} subtitles translated.", flush=True)
        if translated_blocks:
            base, ext = os.path.splitext(output_file)
            partial_file = f"{base}.partial{ext}"
            write_srt(partial_file, header, translated_blocks)
            print(f"  Partial translation saved to:\n  {partial_file}", flush=True)
        else:
            print("  Nothing to save.", flush=True)
        cleanup_wavs(input_file)
        stop_ollama()
        print()
        sys.exit(0)

    write_srt(output_file, header, translated_blocks)
    cleanup_wavs(input_file)
    end_timer = time.time()
    duration = end_timer - start_timer
    hours, rem = divmod(duration, 3600)
    minutes, seconds = divmod(rem, 60)
    print(f"\n\nTranslation finished in: {int(hours)}:{int(minutes):02}:{seconds:06.3f}\n")

if __name__ == "__main__":
    if len(sys.argv) >= 3:
        os.system("")  # Enable ANSI on Windows
        sys.stdout.write("\033[92m")
        sys.stdout.flush()
        ctx = int(sys.argv[3]) if len(sys.argv) >= 4 else 3
        setup_ollama()
        process_srt(sys.argv[1], sys.argv[2], ctx)
        stop_ollama()
