<img width="1596" height="773" alt="image" src="https://github.com/user-attachments/assets/53384815-faa3-4e4c-9a5f-e703c405c2e5" />

**Faster-Whisper-XXL** — Standalone executable and command line wrappers for Windows 11 x64

**Wrapper for transcribtion and translation via Ollama**

- **transcribe.cmd** — Drag-and-drop launcher for video and audio files. Presents an interactive menu with 6 modes: auto transcription (language detection), auto transcription with speaker diarization, German transcription, English transcription, two-stage translation (Whisper EN → Ollama/mistral-nemo DE), and vocal/background separation. Dropping SRT files directly onto the script skips the menu and goes straight to translation. Ollama is auto-installed and configured for full GPU offloading. Temporary JSON and WAV files are cleaned up automatically after each run.

- **translatesrt.cmd** — Standalone SRT translator. Drop one or more SRT files to translate them from English to German locally via Ollama/mistral-nemo (no cloud, no API key required). Asks for a context block count (0–5) that controls translation coherence vs. speed. 

Output naming: `video.EN.srt` → `video.DE.srt`, or `video.srt` → `video.DE.srt`. Ollama is auto-installed if missing.

## Usage examples:

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

### Max quality with speaker diarization (CUDA)
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

## Wrapper examples:
```
transcribe.cmd "D:\Video.mkv"
transcribe.cmd "D:\Video.EN.srt"
translatesrt.cmd "D:\Video.EN.srt"
translatesrt.cmd "D:\Sub1.EN.srt" "D:\Sub2.EN.srt" "D:\Sub3.EN.srt"
```

## Best practices:
- **Model**: Use `large-v2` for maximum accuracy. `turbo` is a good balance of speed and quality. Never go below `medium` for reliable results.
- **Vocal extraction**: Use `--ff_vocal_extract mdx_kim2` whenever audio contains music or background noise. The MDX23 Kim v2 model outperforms HT Demucs v4 FT and significantly reduces hallucinations caused by non-speech sounds.
- **Beam search**: `--beam_size 5 --best_of 5` gives the best transcription quality at the cost of speed. For quick drafts use `--beam_size 1 --best_of 1`.
- **Temperature**: Use `--temperature 0.0` for deterministic, reproducible output. Avoid higher values unless the model is repeatedly hallucinating identical phrases.
- **Context**: `--condition_on_previous_text true` improves coherence across segments. Disable it for highly noisy or fragmented audio where errors could propagate.
- **Word timestamps**: `--word_timestamps true` enables per-word timing, required for subtitle re-segmentation and burn-in workflows.
- **VAD**: The default `silero_v4_fw` is robust and requires no extra setup. Use `--vad_method pyannote_v3` for the best accuracy — requires a HuggingFace token and prior model download. Avoid `silero_v5_fw` (poor accuracy).
- **Diarization**: `pyannote_v3.1` with `--diarize_device cuda` is the best option without license restrictions. `reverb_v2` is reportedly more accurate but is restricted to personal non-profit use only.
- **GPU**: CUDA is detected automatically. For `large-v2` at least 6 GB VRAM is recommended; for simultaneous Ollama DE translation (mistral-nemo 7.7 GB) at least 10 GB VRAM is required.
- **Ollama translation**: The wrapper configures Ollama with `OLLAMA_KV_CACHE_TYPE=q4_0` and `OLLAMA_FLASH_ATTENTION=1` to keep mistral-nemo fully in GPU memory on a 10 GB card. The Ollama server is restarted automatically to apply these settings.
- **Batch processing**: Pass a folder path with `--batch_recursive` to process all supported media files in a directory tree. Add `--check_files` to skip files that already have a matching SRT output — safe to re-run after interruptions.
- **Output location**: `-o source` saves all output files next to the source file. Use `--output_dir "D:\Output"` to redirect to a fixed folder instead.

## Notes:
- Programs automatically will choose to work on GPU if CUDA is detected.
- For decent transcription use not smaller than `medium` model.

## Standalone Faster-Whisper-XXL info:
- Includes all Standalone Faster-Whisper features plus additional ones, for example:
- Preprocess audio with MDX23 Kim_vocal_v2 vocal extraction model.
- Alternative VAD methods: `silero_v4_fw` (default, most accurate Silero version), `silero_v3`, `silero_v4`, `silero_v5`, `pyannote_v3` (best accuracy overall, CUDA), `pyannote_onnx_v3` (lite pyannote, CUDA), `auditok`, `webrtc`. Avoid `silero_v5_fw` (unreliable).
- Speaker Diarization: `pyannote_v3.0`, `pyannote_v3.1` (faster with CUDA), `reverb_v1`, `reverb_v2` (non-profit use only).
