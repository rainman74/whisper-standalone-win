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

def _has_untranslated(source, result):
    """True if result likely contains untranslated words from the English source.
    Proper nouns (capitalized after sentence-internal punctuation) are excluded."""
    if not source or not result:
        return False
    proper = {m.group().lower()
              for m in re.finditer(r'(?<=[,;.!?] )[A-Z][a-z]{2,}', source)}
    src = {w.lower() for w in re.findall(r'[a-zA-Z]{5,}', source)} - proper
    res = {w.lower() for w in re.findall(r'[a-zA-Z]{5,}', result)}
    return bool(src & res)

def _detect_register(context_blocks, ctx):
    """Returns 'Sie', 'du', or None if register is unclear."""
    if not context_blocks:
        return None
    sie = 0
    du  = 0
    for _, de in context_blocks[-max(ctx, 5):]:
        sie += len(re.findall(r'\bSie\b', de))
        du  += len(re.findall(r'\b[Dd]u\b|\b[Dd]ich\b|\b[Dd]ir\b', de))
    if sie + du < 2:
        return None
    if sie > du * 1.5:
        return 'Sie'
    if du > sie * 1.5:
        return 'du'
    return None

ANALYSIS_CTX_MAX = 10  # max entity-tracking window (capped by ctx)

def _translate_minimal(text):
    """Aggressive fallback: minimal prompt when full prompt fails to translate."""
    prompt = f"[INST] Translate this English text to German. Output ONLY the German translation:\n{text} [/INST]"
    try:
        response = requests.post(f"{OLLAMA_API}/api/generate", json={
            "model": MODEL, "prompt": prompt, "stream": False,
            "options": {"temperature": 0.3, "num_predict": 256,
                        "num_ctx": 4096, "num_gpu": 99}
        }, timeout=60)
        result = response.json().get('response', '').strip()
        result = result.replace('"', '').replace('\u201e', '').replace('\u201c', '').strip()
        return result if result else None
    except:
        return None

def translate_text(text, context_blocks=None, ctx=3, force_variety=False, _allow_retry=True):
    if not text.strip():
        return text

    # Analysis context: last N DE segments for entity/gender tracking (capped by ctx)
    analysis_ctx = min(ctx, ANALYSIS_CTX_MAX)
    analysis_str = ""
    if context_blocks and analysis_ctx > 0:
        for _, de in context_blocks[-analysis_ctx:]:
            analysis_str += f"  {de}\n"

    # Translation context: last 3 EN+DE pairs for style matching
    style_ctx = min(ctx, 10)
    context_str = ""
    if context_blocks and style_ctx > 0:
        for en, de in context_blocks[-style_ctx:]:
            context_str += f"  EN: {en}\n  DE: {de}\n"

    # Inject register rule when dominant form is clear
    register = _detect_register(context_blocks, ctx)
    if register == 'Sie':
        register_rule = "9. Use the formal 'Sie' address form throughout.\n"
    elif register == 'du':
        register_rule = "9. Use the informal 'du' address form throughout.\n"
    else:
        register_rule = ""

    # Only include context sections when context exists
    if context_blocks:
        context_header = (
            f"Entity reference (last {analysis_ctx} segments):\n{analysis_str}\n"
            f"Recent translations:\n{context_str}\n"
        )
    else:
        context_header = ""

    prompt = (
        f"[INST] Role: Professional Subtitle Translator\n\n"
        f"{context_header}"
        f"Translate to German: {text}\n\n"
        f"Rules:\n"
        f"1. Use natural German syntax (Verbzweitstellung, Satzklammer) — never adopt source-language structure.\n"
        f"2. Treat each segment as part of a chain — track subject gender, number, and status from prior context. Never translate in isolation.\n"
        f"3. Determine noun gender first. Align ALL dependent forms (articles, pronouns, adjectives) in correct gender, case (Nom/Gen/Dat/Akk), and number. Never mix genders within a reference chain.\n"
        f"4. Check logical consistency: speaker POV, temporal sequence, and factual references must be coherent across segments.\n"
        f"5. Transfer idioms and metaphors to natural German equivalents — never translate figurative language literally.\n"
        f"6. No anglicisms when German equivalents exist. No domain-specific jargon for everyday expressions. Use period-appropriate vocabulary.\n"
        f"7. Translate EVERY word to German — no English word may remain. This includes interjections, honorifics, and standalone words before punctuation.\n"
        f"8. Vary phrasing — avoid mechanical repetitions from source structure. Fragments stay fragments. Keep concise.\n"
        f"{register_rule}"
        f"Output ONLY the German translation. NEVER add parenthesized hints, notes, analysis, checklists, reasoning, or meta-commentary. [/INST]"
    )
    payload = {
        "model": MODEL,
        "prompt": prompt,
        "stream": False,
        "options": {
            "think": True,
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
        # Strip all parenthesized content FIRST (subtitles are speech, never contain parentheses)
        if result:
            result = re.sub(r'\s*\([^)]*\)', '', result).strip()
            result = result.replace('(', '').replace(')', '').strip()
        # Truncate if result is excessively long (model dumped analysis)
        if result and len(result) > len(text) * 3:
            result = result.split('\n')[0].strip()
        # Remove "English → German" leakage (model mimics context format)
        if ' → ' in result:
            result = result.split(' → ')[-1].strip()
        # Remove "Target: ... Translation: German" leakage
        m = re.search(r'(?i)translation\s*:\s*(.+)', result, re.DOTALL)
        if m:
            result = m.group(1).strip()
        # Preserve trailing punctuation from source
        src = text.strip()
        if src and result:
            if src.endswith('...') or src.endswith('…'):
                if not result.endswith(('...', '…')):
                    result = result.rstrip('.…') + '…'
            elif src[-1] in '.!?':
                if result[-1] not in '.!?…':
                    result += src[-1]
        # Deduplicate repeated sentences within result
        if result:
            sentences = re.split(r'(?<=[.!?])\s+', result)
            if len(sentences) >= 2:
                seen = [sentences[0]]
                for s in sentences[1:]:
                    if all(similarity(s, prev) < 0.7 for prev in seen):
                        seen.append(s)
                result = ' '.join(seen)
        # Collapse double punctuation (but preserve ... ellipsis)
        result = re.sub(r'\.{2}(?!\.)', '.', result)
        result = result.strip()
        # Retry if result contains untranslated words or is too similar to source
        needs_retry = (
            _has_untranslated(text, result)
            or similarity(text.strip(), result.strip()) > 0.7
        )
        if _allow_retry and result and needs_retry:
            retry = translate_text(text, context_blocks, ctx,
                                   force_variety=True, _allow_retry=False)
            if retry and similarity(text.strip(), retry.strip()) <= 0.7:
                result = retry
            else:
                # Aggressive fallback: minimal prompt without complex rules
                minimal = _translate_minimal(text)
                if minimal and similarity(text.strip(), minimal.strip()) <= 0.7:
                    result = minimal
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

FLUSH_EVERY = 20   # write progress to disk every N translated blocks

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
    last_flush = 0
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
                    # Incremental flush
                    if len(translated_blocks) - last_flush >= FLUSH_EVERY:
                        write_srt(output_file, header, translated_blocks)
                        last_flush = len(translated_blocks)
                    continue
            translation = translate_text(current_en, context_blocks, ctx)
            if translated_blocks and similarity(translation, translated_blocks[-1][1]) > 0.8:
                translation = translate_text(current_en, context_blocks, ctx, force_variety=True)
            translated_blocks.append((blocks[i]["timestamp"], translation))
            context_blocks.append((current_en, translation))
            # Incremental flush
            if len(translated_blocks) - last_flush >= FLUSH_EVERY:
                write_srt(output_file, header, translated_blocks)
                last_flush = len(translated_blocks)

    except KeyboardInterrupt:
        print(f"\n\n  [CANCELLED] {len(translated_blocks)} of {total_blocks} subtitles translated.", flush=True)
        if translated_blocks:
            write_srt(output_file, header, translated_blocks)
            print(f"  Partial translation saved to:\n  {output_file}", flush=True)
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
