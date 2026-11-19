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
TARGET_LANG = "de"   # target language: 'de' (default) or 'en'

OLLAMA_TIMEOUT = int(os.environ.get("FWHISPER_OLLAMA_TIMEOUT", "300"))


class TranslationError(Exception):
    pass

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
    print("[FAST-WHISPER] Starting Ollama server ...", flush=True)
    print()
    kwargs = {"stdout": subprocess.DEVNULL, "stderr": subprocess.DEVNULL}
    if sys.platform == "win32":
        kwargs["creationflags"] = subprocess.CREATE_NO_WINDOW
    subprocess.Popen(["ollama", "serve"], **kwargs)
    for _ in range(20):
        time.sleep(1)
        if _server_running():
            return True
    print("[FAST-WHISPER] Ollama server did not respond in time.")
    return False

def _model_present():
    try:
        r = requests.get(f"{OLLAMA_API}/api/tags", timeout=5)
        models = r.json().get("models", [])
        base = MODEL.split(":")[0]
        for m in models:
            name = m.get("name", "")
            if name == MODEL or name.split(":")[0] == base:
                return True
        return False
    except Exception:
        return False

def _ensure_model():
    if _model_present():
        return True
    print(f"[FAST-WHISPER] Model [{MODEL}] not found - downloading ...", flush=True)
    try:
        rc = subprocess.run(["ollama", "pull", MODEL]).returncode
    except Exception as e:
        print(f"[FAST-WHISPER] Model download failed: {e}", flush=True)
        rc = 1
    if rc != 0 or not _model_present():
        print(f"[FAST-WHISPER] Model [{MODEL}] is not available - run: ollama pull {MODEL}", flush=True)
        return False
    print(f"[FAST-WHISPER] Model [{MODEL}] downloaded.", flush=True)
    return True

def _preload_model():
    # Evict first so GPU layer settings are applied fresh on reload
    try:
        requests.post(f"{OLLAMA_API}/api/generate", json={
            "model": MODEL, "prompt": "", "keep_alive": 0
        }, timeout=10)
    except:
        pass
    print(f"[FAST-WHISPER] Preloading [{MODEL}] ...", flush=True)
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
        }, timeout=OLLAMA_TIMEOUT)
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
    # (set by whisper.cmd) are inherited by the server process.
    print(flush=True)
    if _server_running():
        print("[FAST-WHISPER] Restarting Ollama to apply GPU memory settings ...", flush=True)
        stop_ollama()
        time.sleep(3)
    if not _start_server():
        sys.exit(1)
    if not _ensure_model():
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
    """True if result likely contains untranslated words from the source language."""
    if not source or not result:
        return False
    if TARGET_LANG == "de":
        word_re = r'[a-zA-Z]{5,}'
        proper_re = r'(?<=[,;.!?] )[A-Z][a-z]{2,}'
    else:
        word_re = r'[a-zA-ZäöüÄÖÜß]{5,}'
        proper_re = r'(?<=[,;.!?] )[A-ZÄÖÜ][a-zäöüß]{2,}'
    proper = {m.group().lower() for m in re.finditer(proper_re, source)}
    src = {w.lower() for w in re.findall(word_re, source)} - proper
    res = {w.lower() for w in re.findall(word_re, result)}
    return bool(src & res)

def _detect_register(context_blocks, ctx):
    """Returns 'Sie', 'du', or None if register is unclear."""
    if TARGET_LANG != "de":
        return None
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
    src_name = "English" if TARGET_LANG == "de" else "German"
    trg_name = "German" if TARGET_LANG == "de" else "English"
    prompt = f"[INST] Translate this {src_name} text to {trg_name}. Output ONLY the {trg_name} translation:\n{text} [/INST]"
    try:
        response = requests.post(f"{OLLAMA_API}/api/generate", json={
            "model": MODEL, "prompt": prompt, "stream": False,
            "options": {"temperature": 0.3, "num_predict": 256,
                        "num_ctx": 4096, "num_gpu": 99}
        }, timeout=OLLAMA_TIMEOUT)
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

    # Translation context: recent source/target pairs for style matching
    style_ctx = min(ctx, 10)
    src_label = "EN" if TARGET_LANG == "de" else "DE"
    trg_label = "DE" if TARGET_LANG == "de" else "EN"
    context_str = ""
    if context_blocks and style_ctx > 0:
        for src_seg, trg_seg in context_blocks[-style_ctx:]:
            context_str += f"  {src_label}: {src_seg}\n  {trg_label}: {trg_seg}\n"

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

    target_name = "German" if TARGET_LANG == "de" else "English"
    if TARGET_LANG == "de":
        rules = (
            "1. Use natural German syntax (Verbzweitstellung, Satzklammer) — never adopt source-language structure.\n"
            "2. Treat each segment as part of a chain — track subject gender, number, and status from prior context. Never translate in isolation.\n"
            "3. Determine noun gender first. Align ALL dependent forms (articles, pronouns, adjectives) in correct gender, case (Nom/Gen/Dat/Akk), and number. Never mix genders within a reference chain.\n"
            "4. Check logical consistency: speaker POV, temporal sequence, and factual references must be coherent across segments.\n"
            "5. Transfer idioms and metaphors to natural German equivalents — never translate figurative language literally.\n"
            "6. No anglicisms when German equivalents exist. No domain-specific jargon for everyday expressions. Use period-appropriate vocabulary.\n"
            "7. Translate EVERY word to German — no English word may remain. This includes interjections, honorifics, and standalone words before punctuation.\n"
            "8. Vary phrasing — avoid mechanical repetitions from source structure. Fragments stay fragments. Keep concise.\n"
        )
    else:
        rules = (
            "1. Use natural English syntax and idiom — never adopt source-language structure.\n"
            "2. Treat each segment as part of a chain — track subject, number, and status from prior context. Never translate in isolation.\n"
            "3. Keep tense, aspect and modality consistent across segments; align pronouns with their referents.\n"
            "4. Check logical consistency: speaker POV, temporal sequence, and factual references must be coherent across segments.\n"
            "5. Transfer idioms and metaphors to natural English equivalents — never translate figurative language literally.\n"
            "6. No Germanisms when English equivalents exist. No domain-specific jargon for everyday expressions. Use period-appropriate vocabulary.\n"
            "7. Translate EVERY word to English — no German word may remain. This includes interjections, honorifics, and standalone words before punctuation.\n"
            "8. Vary phrasing — avoid mechanical repetitions from source structure. Fragments stay fragments. Keep concise.\n"
        )
    prompt = (
        f"[INST] Role: Professional Subtitle Translator\n\n"
        f"{context_header}"
        f"Translate to {target_name}: {text}\n\n"
        f"Rules:\n"
        f"{rules}"
        f"{register_rule}"
        f"Output ONLY the {target_name} translation. NEVER add parenthesized hints, notes, analysis, checklists, reasoning, or meta-commentary. [/INST]"
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
        response = requests.post(f"{OLLAMA_API}/api/generate", json=payload, timeout=OLLAMA_TIMEOUT)
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
        if not result:
            raise TranslationError("model returned an empty translation")
        return result
    except TranslationError:
        raise
    except Exception as e:
        raise TranslationError(f"request failed: {e}") from e

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

def process_srt(input_file, output_file, ctx=3, quiet_finish=False):
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
            print(f"\r[FAST-WHISPER] {i+1} of {total_blocks} subtitles translated", end="", flush=True)
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
        print(f"\n\n[FAST-WHISPER] Translation cancelled: {len(translated_blocks)} of {total_blocks} subtitles translated.", flush=True)
        if translated_blocks:
            write_srt(output_file, header, translated_blocks)
            print(f"[FAST-WHISPER] Partial translation saved to:\n[FAST-WHISPER] {output_file}", flush=True)
        else:
            print("[FAST-WHISPER] Nothing to save.", flush=True)
        cleanup_wavs(input_file)
        stop_ollama()
        print()
        sys.exit(0)

    except TranslationError as e:
        print(f"\n\n[FAST-WHISPER] Translation failed for {os.path.basename(input_file)}: {e}", flush=True)
        if os.path.exists(output_file):
            try:
                os.remove(output_file)
            except OSError:
                pass
        if translated_blocks:
            base, ext = os.path.splitext(output_file)
            partial = f"{base}.partial{ext}"
            write_srt(partial, header, translated_blocks)
            print(f"[FAST-WHISPER] Partial translation saved to:\n[FAST-WHISPER] {partial}", flush=True)
        else:
            print("[FAST-WHISPER] Nothing to save.", flush=True)
        cleanup_wavs(input_file)
        raise

    write_srt(output_file, header, translated_blocks)
    cleanup_wavs(input_file)
    end_timer = time.time()
    duration = end_timer - start_timer
    hours, rem = divmod(duration, 3600)
    minutes, seconds = divmod(rem, 60)
    if not quiet_finish:
        print(f"\n\n[FAST-WHISPER] Translation finished in: {int(hours)}:{int(minutes):02}:{seconds:06.3f}\n")

def process_batch(job_file, ctx=3):
    global TARGET_LANG
    start_timer = time.time()
    jobs = []
    with open(job_file, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = [p.strip().strip('"') for p in line.split('|')]
            if len(parts) >= 3 and parts[0] and parts[1] and parts[2]:
                jobs.append((parts[0], parts[1], parts[2].lower()))
    total = len(jobs)
    if total == 0:
        print("[FAST-WHISPER] No translation jobs.", flush=True)
        return
    for idx, (src, dst, target) in enumerate(jobs, 1):
        TARGET_LANG = target
        prefix = "" if idx == 1 else "\n"
        print(f"{prefix}[FAST-WHISPER] Translating ({idx} of {total}): {os.path.basename(src)}", flush=True)
        print(flush=True)
        if not os.path.exists(src):
            print(f"[FAST-WHISPER] Source subtitle missing: {os.path.basename(src)}", flush=True)
            continue
        try:
            process_srt(src, dst, ctx, quiet_finish=True)
        except TranslationError as e:
            print(f"[FAST-WHISPER] Translation aborted: {e}", flush=True)
            print(f"[FAST-WHISPER] Batch aborted - {idx - 1} of {total} file(s) completed.", flush=True)
            raise
        except Exception as e:
            print(f"[FAST-WHISPER] Translation aborted: {e}", flush=True)
            print(f"[FAST-WHISPER] Batch aborted - {idx - 1} of {total} file(s) completed.", flush=True)
            raise TranslationError(str(e)) from e
        if os.path.exists(dst):
            print(f"\n\n[FAST-WHISPER] Translation created: {os.path.basename(dst)}", flush=True)
        else:
            print(f"\n\n[FAST-WHISPER] Translation failed - no output written: {os.path.basename(dst)}", flush=True)
    end_timer = time.time()
    duration = end_timer - start_timer
    hours, rem = divmod(duration, 3600)
    minutes, seconds = divmod(rem, 60)
    print(f"\n[FAST-WHISPER] All translations finished in: {int(hours)}:{int(minutes):02}:{seconds:06.3f}\n", flush=True)

# ---------------------------------------------------------------------------
#  TXT translation (plain text: sentences / paragraphs, no timestamps)
# ---------------------------------------------------------------------------

TXT_ABBREVIATIONS_EN = [
    "Mr.", "Mrs.", "Ms.", "Dr.", "Prof.", "Sr.", "Jr.", "St.", "vs.",
    "etc.", "e.g.", "i.e.", "Inc.", "Ltd.", "Corp.", "No.", "Vol.",
    "Fig.", "Rev.", "Gen.", "Sgt.", "Capt.", "Lt.", "Col.", "Maj.",
    "approx.", "dept.", "est.", "govt.", "Jan.", "Feb.", "Mar.",
    "Apr.", "Jun.", "Jul.", "Aug.", "Sep.", "Oct.", "Nov.", "Dec.",
]
TXT_ABBREVIATIONS_DE = [
    "Dr.", "Prof.", "Hr.", "Fr.", "Nr.", "Str.", "ca.", "z.B.",
    "d.h.", "u.a.", "v.a.", "bzgl.", "bzw.", "evtl.", "ggf.",
    "inkl.", "usw.", "etc.", "Abs.", "Abt.", "Bd.", "Jh.",
]
TXT_PLACEHOLDER = "\x00"

TXT_NEUTER_NOUNS = [
    'Stück', 'Mädchen', 'Kind', 'Haus', 'Ende', 'Mal', 'Buch', 'Bild',
    'Fest', 'Tier', 'Spiel', 'Ziel', 'Beispiel', 'Problem', 'Ergebnis',
    'Zeichen', 'System', 'Thema', 'Jahr', 'Land', 'Wort', 'Auto', 'Geld',
    'Recht', 'Teil', 'Mittel', 'Paar', 'Gebäude', 'Unternehmen',
    'Ereignis', 'Verhältnis', 'Verfahren', 'Element',
]
TXT_SUBST_ADJECTIVES = [
    'Brave', 'Unartige', 'Gute', 'Böse', 'Kleine', 'Große', 'Alte',
    'Junge', 'Kranke', 'Gesunde', 'Arme', 'Reiche', 'Fremde', 'Bekannte',
    'Verwandte', 'Angestellte', 'Beamte', 'Jugendliche', 'Erwachsene',
    'Deutsche', 'Angehörige', 'Abgeordnete', 'Verletzte', 'Verstorbene',
    'Verdächtige', 'Angeklagte', 'Vorsitzende',
]
TXT_COLORS_DE = ['rot', 'blau', 'grün', 'schwarz', 'weiß', 'gelb',
                 'braun', 'grau', 'gold', 'silber', 'lila', 'rosa', 'orange']
TXT_CLOTHING_STEMS = ['jacke', 'jacken', 'mantel', 'mäntel', 'hemd',
                      'hemden', 'hose', 'hosen', 'kittel', 'weste',
                      'westen', 'rock', 'kleid', 'anzug', 'coat',
                      'jacket', 'cape']
TXT_SUBORD_CONJ = ['dass', 'weil', 'obwohl', 'wenn', 'obgleich', 'sodass',
                   'sobald', 'solange', 'nachdem', 'bevor', 'damit',
                   'indem', 'sofern', 'falls', 'seitdem', 'ehe']
TXT_MONTHS_DE = ('Januar|Februar|März|April|Mai|Juni|Juli|'
                 'August|September|Oktober|November|Dezember')
TXT_EN_LEAK_FIXES = {
    'completely': 'völlig', 'however': 'jedoch', 'therefore': 'daher',
    'furthermore': 'darüber hinaus', 'meanwhile': 'inzwischen',
    'actually': 'tatsächlich', 'basically': 'grundsätzlich',
    'essentially': 'im Wesentlichen', 'particularly': 'besonders',
    'approximately': 'ungefähr', 'unfortunately': 'leider',
    'immediately': 'sofort', 'obviously': 'offensichtlich',
    'currently': 'derzeit', 'recently': 'kürzlich', 'previously': 'zuvor',
    'additionally': 'zusätzlich', 'especially': 'besonders',
    'significantly': 'erheblich', 'ultimately': 'letztendlich',
    'apparently': 'offenbar', 'frequently': 'häufig',
    'occasionally': 'gelegentlich', 'generally': 'im Allgemeinen',
    'entirely': 'vollständig', 'merely': 'lediglich', 'slightly': 'leicht',
    'largely': 'weitgehend', 'potentially': 'möglicherweise',
    'relatively': 'relativ', 'increasingly': 'zunehmend',
    'primarily': 'hauptsächlich',
}


def _txt_protect_abbreviations(text):
    abbrs = sorted(TXT_ABBREVIATIONS_DE + TXT_ABBREVIATIONS_EN,
                   key=len, reverse=True)
    for abbr in abbrs:
        text = text.replace(abbr, abbr.replace(".", TXT_PLACEHOLDER))
    text = text.replace("...", TXT_PLACEHOLDER * 3)
    return text


def _txt_restore_abbreviations(text):
    return text.replace(TXT_PLACEHOLDER, ".")


def split_sentences_txt(text):
    protected = _txt_protect_abbreviations(text)
    parts = re.split(r'(?<=[.!?])\s+(?=[A-Z\u00C0-\u00DC"\'\u201E\u201C\u00AB(])', protected)
    return [_txt_restore_abbreviations(p).strip() for p in parts if p.strip()]


def build_txt_chunks(text, sentences_per_chunk=2):
    paragraphs = re.split(r'\n\s*\n', text.strip())
    chunks = []
    para_indices = []
    for pi, para in enumerate(paragraphs):
        para = para.strip()
        if not para:
            continue
        sentences = split_sentences_txt(para)
        for i in range(0, len(sentences), sentences_per_chunk):
            chunks.append(" ".join(sentences[i:i + sentences_per_chunk]))
            para_indices.append(pi)
    return chunks, para_indices


def _txt_fix_german(text):
    for en, de in TXT_EN_LEAK_FIXES.items():
        text = re.sub(rf'\b{en}\b', de, text, flags=re.IGNORECASE)
    for noun in TXT_NEUTER_NOUNS:
        text = re.sub(rf'\beine\b(\s+{re.escape(noun)})\b', r'ein\1', text)
        text = re.sub(rf'\bEine\b(\s+{re.escape(noun)})\b', r'Ein\1', text)
    for adj in TXT_SUBST_ADJECTIVES:
        text = re.sub(rf'\bder {re.escape(adj)}\b', f'der {adj}n', text)
    for color in TXT_COLORS_DE:
        for stem in TXT_CLOTHING_STEMS:
            text = re.sub(rf'\b{color}{stem}\w+', f'{color} gekleidet',
                          text, flags=re.IGNORECASE)
    text = re.sub(rf'auf de[mn] (\d+\.\s*(?:{TXT_MONTHS_DE}))', r'am \1', text)
    for conj in TXT_SUBORD_CONJ:
        text = re.sub(rf'(\w) ({conj})\b', rf'\1, \2', text)
    text = re.sub(r',\s*,', ',', text)
    text = re.sub(r'\b(dass|und|oder|aber|auch|noch|schon|dann|denn)\s+\1\b',
                  r'\1', text, flags=re.IGNORECASE)
    text = re.sub(r'\.\.(?!\.)', '.', text)
    return text


def _txt_postprocess(text, target):
    text = re.sub(
        r'\n\s*(?:'
        r'Corrected |Corrections?\s|Changes?\s|Notes?\s*:|Explanation|Revision'
        r'|Korrektur|Änderungen|Übersetzung\s*[:(]|Translation\s'
        r'|Original\s*[:(]|\(Translation\b|\(Korrektur\b|\(Übersetzung\b'
        r').*', '', text, flags=re.DOTALL | re.IGNORECASE)
    if len(text) > 2 and text[0] == '"' and text[-1] == '"':
        text = text[1:-1]
    for ch in ['\u201e', '\u201c', '\u201d']:
        text = text.replace(ch, '')
    text = re.sub(r'  +', ' ', text)
    if target == "de":
        text = _txt_fix_german(text)
    return text.strip()


TXT_SYSTEM_TRANSLATE = (
    "You are a professional translator. Translate the text into {tgt}.\n"
    "The source language may be English or German - detect it automatically.\n"
    "- Produce natural, fluent {tgt} with correct grammar, gender, and case.\n"
    "- Use natural {tgt} sentence structure. Do not mirror the source syntax.\n"
    "- Use exclusively established {tgt} vocabulary. Never invent compound words.\n"
    "  If unsure, use a descriptive phrase instead.\n"
    "- Translate ALL terms completely. No source-language words may remain.\n"
    "- Preserve punctuation, parentheses, and dashes exactly.\n"
    "- Output ONLY the translation. No notes, explanations, headings, or labels."
)

TXT_SYSTEM_TRANSLATE_DE = (
    "\n- Use natural German syntax (Verbzweitstellung, Satzklammer).\n"
    "- Translate EVERY word to German - no English word may remain.\n"
    "- Check logical consistency and grammatical gender/case across sentences."
)

TXT_SYSTEM_TRANSLATE_EN = (
    "\n- Use natural English syntax and idiom.\n"
    "- Translate EVERY word to English - no German word may remain.\n"
    "- Check tense, aspect and pronouns for consistency across sentences."
)

TXT_SYSTEM_REVIEW = (
    "You are a {tgt} translation proofreader.\n"
    "Correct the draft translation based on the original. You may restructure freely.\n\n"
    "- Terminological consistency: replace ALL remaining source-language terms with {tgt} equivalents.\n"
    "- Grammatical precision: fix gender agreement, case errors, and verb conjugation.\n"
    "- Vocabulary: replace invented compound words with real {tgt} words or descriptive phrases.\n"
    "- Idiomatic correctness: replace word-for-word translations with natural {tgt} phrasing.\n"
    "- Structural integrity: do not add or omit information. Match the original precisely.\n"
    "- CRITICAL: Output ONLY the corrected {tgt} text.\n"
    "  Do NOT output change notes, explanations, or 'Corrected' sections."
)


def _txt_call(system_prompt, user_msg, temperature=0.05):
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_msg},
        ],
        "stream": False,
        "options": {
            "num_ctx": 4096,
            "num_gpu": 99,
            "temperature": temperature,
            "num_predict": 768,
            "repeat_penalty": 1.1,
            "top_p": 0.7,
        }
    }
    response = requests.post(f"{OLLAMA_API}/api/chat", json=payload, timeout=OLLAMA_TIMEOUT)
    return response.json().get("message", {}).get("content", "").strip()


def translate_txt_chunk(text, target, prev_sentences, next_sentences):
    if not text.strip():
        return text
    src_name = "German" if target == "en" else "English"
    tgt_name = "German" if target == "de" else "English"
    system = TXT_SYSTEM_TRANSLATE.format(tgt=tgt_name)
    system += TXT_SYSTEM_TRANSLATE_DE if target == "de" else TXT_SYSTEM_TRANSLATE_EN
    user_msg = ""
    if prev_sentences:
        user_msg += "Previous translated sentences (for consistency):\n"
        user_msg += "\n".join(prev_sentences) + "\n\n"
    if next_sentences:
        user_msg += "Next source sentences (for context only, do not translate):\n"
        user_msg += " ".join(next_sentences) + "\n\n"
    user_msg += f"Translate:\n{text}"
    try:
        draft = _txt_call(system, user_msg, temperature=0.05)
        draft = _txt_postprocess(draft, target)
        if not draft:
            raise TranslationError("model returned an empty translation")
        review_system = TXT_SYSTEM_REVIEW.format(tgt=tgt_name)
        review_msg = f"Original:\n{text}\n\nTranslation ({tgt_name}):\n{draft}"
        corrected = _txt_call(review_system, review_msg, temperature=0.0)
        corrected = _txt_postprocess(corrected, target)
        return corrected if corrected else draft
    except TranslationError:
        raise
    except Exception as e:
        raise TranslationError(f"request failed: {e}") from e


def _read_txt_file(path):
    for enc in ("utf-8-sig", "utf-8", "cp1252", "latin-1"):
        try:
            with open(path, "r", encoding=enc) as f:
                return f.read()
        except UnicodeDecodeError:
            continue
    with open(path, "r", encoding="latin-1") as f:
        return f.read()


def _write_txt_output(path, translated_chunks, para_indices):
    with open(path, "w", encoding="utf-8", newline="") as f:
        prev_para = None
        for i, chunk in enumerate(translated_chunks):
            if prev_para is not None and para_indices[i] != prev_para:
                f.write("\r\n\r\n")
            elif prev_para is not None:
                f.write(" ")
            f.write(chunk)
            prev_para = para_indices[i]
        f.write("\r\n")


def _txt_partial_path(dst):
    base, _ext = os.path.splitext(dst)
    return base + ".partial.txt"


def process_txt_file(src, dst, ctx=3, target="de"):
    start_timer = time.time()
    content = _read_txt_file(src)
    chunks, para_indices = build_txt_chunks(content)
    total = len(chunks)
    if total == 0:
        print(f"[FAST-WHISPER] No text found in {os.path.basename(src)} - skipped.", flush=True)
        return False

    translated = []
    prev_translated_sentences = []
    all_src_sentences = []
    for chunk in chunks:
        all_src_sentences.append(split_sentences_txt(chunk))

    try:
        for i, chunk in enumerate(chunks):
            print(f"\r[FAST-WHISPER] Translating {i + 1} of {total} chunks ...  ", end="", flush=True)
            next_sentences = []
            for j in range(i + 1, len(chunks)):
                next_sentences.extend(all_src_sentences[j])
                if len(next_sentences) >= ctx:
                    break
            translation = translate_txt_chunk(
                chunk, target,
                prev_translated_sentences[-ctx:] if ctx > 0 else [],
                next_sentences[:ctx] if ctx > 0 else [])

            if translated and similarity(translation, translated[-1]) > 0.8:
                translation = translate_txt_chunk(
                    chunk, target,
                    prev_translated_sentences[-ctx:] if ctx > 0 else [],
                    next_sentences[:ctx] if ctx > 0 else [])

            translated.append(translation)
            prev_translated_sentences.extend(split_sentences_txt(translation))

    except KeyboardInterrupt:
        print(f"\n\n[FAST-WHISPER] Translation cancelled: {len(translated)} of {total} chunks translated.", flush=True)
        if translated:
            partial = _txt_partial_path(dst)
            _write_txt_output(partial, translated, para_indices)
            print(f"[FAST-WHISPER] Partial translation saved to:\n[FAST-WHISPER] {partial}", flush=True)
        else:
            print("[FAST-WHISPER] Nothing to save.", flush=True)
        stop_ollama()
        sys.exit(0)

    except TranslationError as e:
        print(f"\n\n[FAST-WHISPER] Translation failed for {os.path.basename(src)}: {e}", flush=True)
        if os.path.exists(dst):
            try:
                os.remove(dst)
            except OSError:
                pass
        if translated:
            partial = _txt_partial_path(dst)
            _write_txt_output(partial, translated, para_indices)
            print(f"[FAST-WHISPER] Partial translation saved to:\n[FAST-WHISPER] {partial}", flush=True)
        else:
            print("[FAST-WHISPER] Nothing to save.", flush=True)
        raise

    _write_txt_output(dst, translated, para_indices)
    duration = time.time() - start_timer
    hours, rem = divmod(duration, 3600)
    minutes, seconds = divmod(rem, 60)
    print(f"\n\n[FAST-WHISPER] Translation finished in: {int(hours)}:{int(minutes):02}:{seconds:06.3f}\n", flush=True)
    return True


def process_txt_batch(job_file, ctx=3, target="de"):
    start_timer = time.time()
    jobs = []
    with open(job_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = [p.strip().strip('"') for p in line.split("|")]
            if len(parts) >= 2 and parts[0] and parts[1]:
                jobs.append((parts[0], parts[1]))
    total = len(jobs)
    if total == 0:
        print("[FAST-WHISPER] No TXT translation jobs.", flush=True)
        return
    for idx, (src, dst) in enumerate(jobs, 1):
        prefix = "" if idx == 1 else "\n"
        print(f"{prefix}[FAST-WHISPER] Translating ({idx} of {total}): {os.path.basename(src)}", flush=True)
        print(flush=True)
        if not os.path.exists(src):
            print(f"[FAST-WHISPER] Source file missing: {os.path.basename(src)}", flush=True)
            continue
        if os.path.exists(dst):
            print(f"[FAST-WHISPER] Target already exists - skipped: {os.path.basename(dst)}", flush=True)
            continue
        try:
            created = process_txt_file(src, dst, ctx, target)
        except TranslationError as e:
            print(f"[FAST-WHISPER] Translation aborted: {e}", flush=True)
            print(f"[FAST-WHISPER] Batch aborted - {idx - 1} of {total} file(s) completed.", flush=True)
            raise
        if created:
            print(f"\n\n[FAST-WHISPER] Translation created: {os.path.basename(dst)}", flush=True)
        else:
            print(f"\n\n[FAST-WHISPER] Nothing written: {os.path.basename(dst)}", flush=True)
    duration = time.time() - start_timer
    hours, rem = divmod(duration, 3600)
    minutes, seconds = divmod(rem, 60)
    print(f"\n[FAST-WHISPER] All TXT translations finished in: {int(hours)}:{int(minutes):02}:{seconds:06.3f}\n", flush=True)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--txt":
        src = sys.argv[2]
        dst = sys.argv[3] if len(sys.argv) >= 4 else src
        ctx = int(sys.argv[4]) if len(sys.argv) >= 5 else 3
        target = sys.argv[5].lower() if len(sys.argv) >= 6 else "de"
        if len(sys.argv) >= 7:
            MODEL = sys.argv[6]
        if target not in ("de", "en"):
            print(f"[FAST-WHISPER] Unknown target '{target}'. Use 'de' or 'en'.", flush=True)
            sys.exit(1)
        if not os.path.exists(src):
            print(f"[FAST-WHISPER] Source file not found: {src}", flush=True)
            sys.exit(1)
        setup_ollama()
        try:
            process_txt_file(src, dst, ctx, target)
        except TranslationError as e:
            print("[FAST-WHISPER] Translation aborted - see error above.", flush=True)
            stop_ollama()
            sys.exit(1)
        stop_ollama()
        sys.exit(0)
    if len(sys.argv) >= 3 and sys.argv[1] == "--txt-batch":
        job = sys.argv[2]
        ctx = int(sys.argv[3]) if len(sys.argv) >= 4 else 3
        target = sys.argv[4].lower() if len(sys.argv) >= 5 else "de"
        if len(sys.argv) >= 6:
            MODEL = sys.argv[5]
        if target not in ("de", "en"):
            print(f"[FAST-WHISPER] Unknown target '{target}'. Use 'de' or 'en'.", flush=True)
            sys.exit(1)
        if not os.path.exists(job):
            print(f"[FAST-WHISPER] Job file not found: {job}", flush=True)
            sys.exit(1)
        setup_ollama()
        try:
            process_txt_batch(job, ctx, target)
        except TranslationError as e:
            print("[FAST-WHISPER] Translation aborted - see error above.", flush=True)
            stop_ollama()
            sys.exit(1)
        stop_ollama()
        sys.exit(0)
    if len(sys.argv) >= 3 and sys.argv[1] == "--batch":
        ctx = int(sys.argv[3]) if len(sys.argv) >= 4 else 3
        if len(sys.argv) >= 5:
            MODEL = sys.argv[4]
        setup_ollama()
        try:
            process_batch(sys.argv[2], ctx)
        except TranslationError as e:
            print("[FAST-WHISPER] Translation aborted - see error above.", flush=True)
            stop_ollama()
            sys.exit(1)
        stop_ollama()
        sys.exit(0)
    if len(sys.argv) >= 3:
        ctx = int(sys.argv[3]) if len(sys.argv) >= 4 else 3
        if len(sys.argv) >= 5:
            MODEL = sys.argv[4]
        if len(sys.argv) >= 6:
            TARGET_LANG = sys.argv[5].lower()
        setup_ollama()
        try:
            process_srt(sys.argv[1], sys.argv[2], ctx)
        except TranslationError as e:
            print("[FAST-WHISPER] Translation aborted - see error above.", flush=True)
            stop_ollama()
            sys.exit(1)
        stop_ollama()
