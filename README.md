<img width="1596" height="773" alt="image" src="https://github.com/user-attachments/assets/53384815-faa3-4e4c-9a5f-e703c405c2e5" />

Standalone executable und command line wrappers.

**Faster-Whisper-XXL** - executable is x64 compatible with Windows 10 + 11
**transcribe.cmd** - tbd
**translatesrt.cmd** - tbd
     
## Usage examples:
* `faster-whisper-xxl.exe "D:\videofile.mkv" --language English --model medium --output_dir source`
* `faster-whisper-xxl.exe "D:\Folder" -l en -m turbo --sentence --batch_recursive`
* `faster-whisper-xxl.exe "D:\videofile.mkv" -l ja -m medium --task translate --standard -o source`      
* `faster-whisper-xxl.exe --help`

## Wrapper examples:
* `transcribe.cmd "D:\Video.mkv"`
* `translatesrt.cmd "D:\Video.srt"`

## Notes:
Programs automatically will choose to work on GPU if CUDA is detected.
For decent transcription use not smaller than `medium` model.

## Standalone Faster-Whisper-XXL info:
Includes all Standalone Faster-Whisper features + the additional ones, for example:
Preprocess audio with MDX23 Kim_vocal_v2 vocal extraction model.
Alternative VAD methods: 'silero_v3', 'silero_v4', 'silero_v5', 'pyannote_v3', 'pyannote_onnx_v3', 'auditok', 'webrtc'.
Speaker Diarization.
