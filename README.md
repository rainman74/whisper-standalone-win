<img alt="image" src="https://github.com/user-attachments/assets/53384815-faa3-4e4c-9a5f-e703c405c2e5" />

**Faster-Whisper-XXL** — Standalone executable and command line wrappers for Windows 10/11 x64

---

## Requirements

- Windows 10/11 x64
- **Python 3.x** with `requests` for the Ollama-based translation (the wrappers run `pip install requests` if it is missing)
- **Ollama** for the translation steps (modes 3-6 when a translation is needed): installed automatically if missing; missing models are downloaded automatically on first use (internet required, uses `ollama pull`). Optional manual pre-pull: `ollama pull mistral-nemo` (and `ollama pull translategemma:12b` for context option B)
- Free disk space for the Whisper model cache in `_models/` (several GB)
- For CUDA: an NVIDIA GPU. `large-v2` needs at least 6 GB VRAM; running the Ollama DE translation on the same GPU (mistral-nemo about 7.1 GB, translategemma:12b about 8.1 GB for option B) needs at least 10 GB VRAM. CPU-only works but is much slower.

The Whisper executable itself is fully standalone — Python and Ollama are only needed for the translation features.

---

## whisper.cmd

Drag-and-drop launcher for video and audio files with an interactive mode menu.

**Modes:**
- `[1]` Auto transcription (language auto-detect) → `<name>.<LANG>.srt` (detected language in uppercase, e.g. `.DE.srt`, `.EN.srt`, `.FR.srt`)
- `[2]` Auto transcription + speaker diarization → same language-based naming
- `[3]` German transcription (language forced) → `<name>.DE.srt`
- `[4]` English transcription (language forced) → `<name>.EN.srt`
- `[5]` Translate GERMAN: Whisper `--language de` → `<name>.DE.srt`, then Ollama translates DE→EN → `<name>.EN.srt` (context option B uses translategemma:12b)
- `[6]` Translate ENGLISH: Whisper `--language en` → `<name>.EN.srt`, then Ollama translates EN→DE → `<name>.DE.srt`
- `[7]` Vocal/background separation — outputs clean background WAV

**Existing subtitles are reused (modes 1–6):**
- Existing `<name>.DE.srt` / `<name>.EN.srt` next to a media file are reused instead of running Whisper again.
- If the subtitle a mode needs is missing but the other language exists, it is produced via Ollama translation (both directions: DE→EN and EN→DE).
- If all subtitles a mode needs already exist, the file is skipped (`[FAST-WHISPER] Subtitle already exists ...`) — nothing is re-transcribed.
- Modes 1/2 skip a file when `<name>.srt` or any `<name>.<LANG>.srt` (e.g. `.DE.srt`, `.EN.srt`, `.FR.srt`) already exists.
- Auto modes write the detected language as an uppercase suffix: `de` → `<name>.DE.srt`, `en` → `<name>.EN.srt`, `fr` → `<name>.FR.srt`, etc.
- In modes 3–6 a plain `<name>.srt` is not reused (it only counts as the English version on SRT drops).
- Folder drops: media files are found recursively; sidecar files (`*.srt`, `*.json`, `*.wav`, …) are ignored.
- Whisper runs once for all files that need transcription (model loaded once per run); Ollama translations of all files run in one batch (server/model loaded once per run).

**Features:**
- Drop SRT files directly onto the script to skip the menu and go straight to translation — no Whisper involved
- SRT direction is chosen per file: `.EN.srt` → `.DE.srt`, `.DE.srt` → `.EN.srt`, plain `.srt` is treated as English → `.DE.srt`; existing target subtitles are skipped
- Any other language suffix (e.g. `.FR.srt`, `.ES.srt`, `.YUE.srt`) is translated to **both** `<name>.DE.srt` and `<name>.EN.srt` — whichever of them is missing
- A plain `<name>.srt` counts as the English version: dropping `<name>.DE.srt` is skipped when `<name>.srt` or `<name>.EN.srt` already exists
- Ollama is installed automatically if missing; missing Ollama models are downloaded automatically on the first translation (internet required) — if the download fails, the run aborts with a clear message
- Ollama is restarted with GPU-friendly settings (`OLLAMA_KV_CACHE_TYPE=q4_0`, `OLLAMA_FLASH_ATTENTION=1`) — this stops other running Ollama sessions
- JSON and intermediate WAV files are removed automatically after each run
- Multiple files: one Whisper run and one Ollama batch per invocation (no repeated model loading)
- Transcription defaults: `large-v2`, `--compute_type float16`, `--vad_method pyannote_v3` (CUDA auto-detected)
- `Ctrl+C` cancels the current run: Whisper stderr is captured (no Python tracebacks) and the script ends with `[FAST-WHISPER] Cancelled by user.` (cmd still shows its own `Batchvorgang abbrechen (J/N)?` prompt — answer `N` so the script can clean up)

---

## Usage examples

### Basic
```
faster-whisper-xxl.exe "D:\videofile.mkv" --language English --model medium --output_dir source
faster-whisper-xxl.exe "D:\Folder" -l en -m turbo --sentence --batch_recursive
faster-whisper-xxl.exe --help
```

### Max quality transcription
```
faster-whisper-xxl.exe "D:\videofile.mkv" -l de -m large-v2 -o source --standard -f json srt ^
  --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 ^
  --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 ^
  --word_timestamps true --condition_on_previous_text true --check_files --print_progress
```

### Max quality + speaker diarization (CUDA)
```
faster-whisper-xxl.exe "D:\videofile.mkv" -l en -m large-v2 -o source --standard -f srt ^
  --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 ^
  --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 ^
  --word_timestamps true --condition_on_previous_text true ^
  --diarize pyannote_v3.1 --diarize_device cuda --print_progress
```

### Whisper built-in translation to English
```
faster-whisper-xxl.exe "D:\videofile.mkv" -l ja -m large-v2 --task translate -o source --standard -f srt ^
  --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --patience 2.0 --temperature 0.0 ^
  --word_timestamps true --condition_on_previous_text true --print_progress
```

### Batch folder processing
```
faster-whisper-xxl.exe "D:\VideoFolder" -l en -m large-v2 -o source --standard -f srt ^
  --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --temperature 0.0 ^
  --word_timestamps true --condition_on_previous_text true --batch_recursive --skip
```

## Wrapper examples
```
whisper.cmd "D:\Video.mkv"
whisper.cmd "D:\Video.EN.srt"
whisper.cmd "D:\Sub1.EN.srt" "D:\Sub2.EN.srt" "D:\Sub3.EN.srt"
```

---

## Best practices

- **Model**: Use `large-v2` for maximum accuracy. `turbo` is a good balance of speed and quality. Never go below `medium` for reliable results.
- **Vocal extraction**: Use `--ff_vocal_extract mdx_kim2` whenever audio contains music or background noise. MDX23 Kim v2 outperforms HT Demucs v4 FT and significantly reduces hallucinations from non-speech sounds.
- **Beam search**: `--beam_size 5 --best_of 5` gives the best transcription quality at the cost of speed. For quick drafts use `--beam_size 1 --best_of 1`.
- **Temperature**: Use `--temperature 0.0` for deterministic, reproducible output. Avoid higher values unless the model is hallucinating repetitive phrases.
- **Context**: `--condition_on_previous_text true` improves coherence across segments. Disable for highly noisy or fragmented audio where errors could propagate.
- **Word timestamps**: `--word_timestamps true` enables per-word timing — required for subtitle re-segmentation and burn-in workflows.
- **VAD**: The wrappers use `--vad_method pyannote_v3` (best accuracy; models are bundled, no HuggingFace token needed). Its first load adds roughly 15 s per run — switch to `silero_v4_fw` if you prefer a faster start. Avoid `silero_v5_fw` (poor accuracy).
- **Compute type**: `float16` gives the best GPU quality; the wrappers set `--compute_type float16` explicitly. `--device` is left on its default (CUDA when detected).
- **Diarization**: `pyannote_v3.1` with `--diarize_device cuda` is the best option without license restrictions. `reverb_v2` is reportedly more accurate but restricted to personal non-profit use only.
- **GPU**: CUDA is detected automatically. `large-v2` needs at least 6 GB VRAM; running the Ollama DE translation on the same GPU (mistral-nemo about 7.1 GB, translategemma:12b about 8.1 GB for option B) needs at least 10 GB VRAM.
- **Ollama translation**: The wrapper sets `OLLAMA_KV_CACHE_TYPE=q4_0` and `OLLAMA_FLASH_ATTENTION=1` to keep mistral-nemo fully in GPU memory. The server is restarted automatically to apply these settings — this stops every running `ollama.exe`, so other Ollama work is interrupted.
- **Batch processing**: Pass a folder path with `--batch_recursive` to process all media files in a directory tree. `--check_files` validates the media files before processing; it does **not** skip existing subtitles. To skip files that already have a matching SRT, use `--skip` (works with a folder or wildcard input, not with single dropped files). Without it, existing SRTs are overwritten.
- **Output location**: `-o source` places all output files next to the source file. Use `--output_dir "D:\Output"` to redirect to a fixed folder.

---

## Notes

- CUDA is detected automatically; GPU is preferred if available.
- For reliable transcription quality, use at least the `medium` model.

---

## Standalone Faster-Whisper-XXL

Includes all Standalone Faster-Whisper features plus:

**Vocal extraction:**
- `mdx_kim2` — MDX23 Kim vocal v2 (recommended, outperforms HT Demucs v4 FT)

**VAD methods (`--vad_method`):**
- `silero_v4_fw` — Default; most accurate Silero version
- `silero_v3` / `silero_v4` / `silero_v5` — Original Silero code variants
- `pyannote_v3` — Best overall accuracy, CUDA supported
- `pyannote_onnx_v3` — Lite pyannote, similar accuracy to Silero v4, CUDA supported
- `auditok` — Audio Activity Detection (not a VAD)
- `webrtc` — Low accuracy, outdated
- ~~`silero_v5_fw`~~ — Avoid (poor accuracy, fatal quirks)

**Speaker Diarization (`--diarize`):**
- `pyannote_v3.0` — Fastest for CPU
- `pyannote_v3.1` — Faster with CUDA (recommended)
- `reverb_v1` — Allegedly better than pyannote v3
- `reverb_v2` — Allegedly best accuracy; personal non-profit use only
