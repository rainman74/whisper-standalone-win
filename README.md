<img alt="image" src="https://github.com/user-attachments/assets/53384815-faa3-4e4c-9a5f-e703c405c2e5" />

**Faster-Whisper-XXL** — Standalone executable and command line wrappers for Windows 10/11 x64

---

## transcribe.cmd

Drag-and-drop launcher for video and audio files with an interactive mode menu.

**Modes:**
- `[1]` Auto transcription (language auto-detect)
- `[2]` Auto transcription + speaker diarization
- `[3]` German transcription (language forced)
- `[4]` English transcription (language forced)
- `[5]` Two-stage translation: Whisper → EN SRT, then Ollama/mistral-nemo → DE SRT
- `[6]` Vocal/background separation — outputs clean background WAV

**Features:**
- Drop SRT files directly onto the script to skip the menu and go straight to translation
- Ollama is auto-installed and configured for full GPU offloading
- JSON and WAV temp files are cleaned up automatically after each run

---

## translatesrt.cmd

Standalone SRT translator — English to German via Ollama/mistral-nemo, fully local.

**Features:**
- Drop one or more SRT files for batch processing
- No cloud, no API key required
- Selectable context block count (0–5): controls translation coherence vs. speed
- Output naming: `video.EN.srt` → `video.DE.srt`, or `video.srt` → `video.DE.srt`
- Ollama is auto-installed if missing

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
  --word_timestamps true --condition_on_previous_text true --batch_recursive --check_files
```

## Wrapper examples
```
transcribe.cmd "D:\Video.mkv"
transcribe.cmd "D:\Video.EN.srt"
translatesrt.cmd "D:\Video.EN.srt"
translatesrt.cmd "D:\Sub1.EN.srt" "D:\Sub2.EN.srt" "D:\Sub3.EN.srt"
```

---

## Best practices

- **Model**: Use `large-v2` for maximum accuracy. `turbo` is a good balance of speed and quality. Never go below `medium` for reliable results.
- **Vocal extraction**: Use `--ff_vocal_extract mdx_kim2` whenever audio contains music or background noise. MDX23 Kim v2 outperforms HT Demucs v4 FT and significantly reduces hallucinations from non-speech sounds.
- **Beam search**: `--beam_size 5 --best_of 5` gives the best transcription quality at the cost of speed. For quick drafts use `--beam_size 1 --best_of 1`.
- **Temperature**: Use `--temperature 0.0` for deterministic, reproducible output. Avoid higher values unless the model is hallucinating repetitive phrases.
- **Context**: `--condition_on_previous_text true` improves coherence across segments. Disable for highly noisy or fragmented audio where errors could propagate.
- **Word timestamps**: `--word_timestamps true` enables per-word timing — required for subtitle re-segmentation and burn-in workflows.
- **VAD**: Default `silero_v4_fw` is robust and requires no extra setup. Use `--vad_method pyannote_v3` for the best accuracy — requires a HuggingFace token and prior model download. Avoid `silero_v5_fw` (poor accuracy).
- **Diarization**: `pyannote_v3.1` with `--diarize_device cuda` is the best option without license restrictions. `reverb_v2` is reportedly more accurate but restricted to personal non-profit use only.
- **GPU**: CUDA is detected automatically. `large-v2` needs at least 6 GB VRAM; for parallel Ollama DE translation (mistral-nemo 7.7 GB) at least 10 GB VRAM is required.
- **Ollama translation**: The wrapper sets `OLLAMA_KV_CACHE_TYPE=q4_0` and `OLLAMA_FLASH_ATTENTION=1` to keep mistral-nemo fully in GPU memory. The server is restarted automatically to apply these settings.
- **Batch processing**: Pass a folder path with `--batch_recursive` to process all media files in a directory tree. Add `--check_files` to skip files that already have a matching SRT — safe to re-run after interruptions.
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
