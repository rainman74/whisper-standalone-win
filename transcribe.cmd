@echo off
color 0A
setlocal enabledelayedexpansion

:: ============================================================
::  Faster-Whisper-XXL  |  Unified Launcher
:: ============================================================

:INIT
if "%~1"=="" (
    echo.
    echo  No file detected.
    echo  Drop a video or audio file onto this script.
    echo.
    pause
    exit /b
)

:: Tool path
set "DP=%~dp0"

:: Save extension of first file BEFORE shift consumes the args
set "_ext=%~x1"

:: Collect all dropped files
set "file_list="
set "file_count=0"

:COLLECT
set /a file_count+=1
set "file[!file_count!]=%~1"
set "file_list=!file_list! "%~1""
shift
if not "%~1"=="" goto COLLECT

:: SRT dropped directly -> skip menu, go straight to translation
if /i "%_ext%"==".srt" goto MODE_SRT_TRANSLATE

:: ============================================================
::  Banner + Menu
:: ============================================================
cls
color 0A
echo.
echo.
echo      8""""                                    8   8  8                                       8   8 8   8 8
echo      8     eeeee eeeee eeeee eeee eeeee       8   8  8 e   e e  eeeee eeeee eeee eeeee        8 8   8 8  8
echo      8eeee 8   8 8   "   8   8    8   8       8e  8  8 8   8 8  8   " 8   8 8    8   8        eee   eee  8e
echo      88    8eee8 8eeee   8e  8eee 8eee8e eeee 88  8  8 8eee8 8e 8eeee 8eee8 8eee 8eee8e eeee 88  8 88  8 88
echo      88    88  8    88   88  88   88   8      88  8  8 88  8 88    88 88    88   88   8      88  8 88  8 88
echo      88    88  8 8ee88   88  88ee 88   8      88ee8ee8 88  8 88 8ee88 88    88ee 88   8      88  8 88  8 88eee
echo.
echo.
echo  !file_count! file(s) loaded.
echo.
echo  -------------------------------------------------------
echo   What do you want to do?
echo  -------------------------------------------------------
echo.
echo   [1]  Transcribe AUTO          (language auto-detect)
echo   [2]  Transcribe AUTO+DIARIZE  (speaker recognition)
echo   [3]  Transcribe GERMAN        (language forced)
echo   [4]  Transcribe ENGLISH       (language forced)
echo   [5]  Translate                (Whisper EN + DE via Ollama)
echo   [6]  Background Extraction    (remove vocals)
echo.
choice /c 123456E /n /m "  Select [1-6, E = Abort]: "

if errorlevel 7 goto END
if errorlevel 6 goto MODE_BACKGROUND
if errorlevel 5 goto MODE_TRANSLATE
if errorlevel 4 goto MODE_EN
if errorlevel 3 goto MODE_DE
if errorlevel 2 goto MODE_DIARIZE
if errorlevel 1 goto MODE_AUTO

:: ============================================================
::  [1] AUTO
:: ============================================================
:MODE_AUTO
set "COMMON=--beep_off -pp -o source --batch_recursive --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
echo.
echo  [AUTO] Starting transcription (language auto-detect) ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% %file_list%
goto CLEANUP_JSON

:: ============================================================
::  [2] AUTO + DIARIZE
:: ============================================================
:MODE_DIARIZE
set "COMMON=--beep_off -pp -o source --batch_recursive --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
echo.
echo  [DIARIZE] Starting transcription with speaker recognition ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% %file_list% --diarize pyannote_v3.1 --diarize_device cuda
goto CLEANUP_JSON

:: ============================================================
::  [3] GERMAN
:: ============================================================
:MODE_DE
set "COMMON=--beep_off -pp -o source --batch_recursive --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
echo.
echo  [DE] Starting transcription in German ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% %file_list% --language de
goto CLEANUP_JSON

:: ============================================================
::  [4] ENGLISH
:: ============================================================
:MODE_EN
set "COMMON=--beep_off -pp -o source --batch_recursive --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
echo.
echo  [EN] Starting transcription in English ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% %file_list% --language en
goto CLEANUP_JSON

:: ============================================================
::  [5] TRANSLATE  (Whisper EN-SRT + Ollama DE-SRT)
:: ============================================================
:MODE_TRANSLATE
call :ASK_CONTEXT
if /i "!CTX!"=="E" goto CLEANUP_EXIT
echo.
echo  [TRANSLATE] Checking Ollama ...
echo.
call :OLLAMA_SETUP

set "TRANSLATE_FLAGS=--beep_off -pp -o source --standard -f srt -m large-v2 --task translate --ff_vocal_extract mdx_kim2 --ff_dump --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"

set "i=0"
:TRANSLATE_LOOP
set /a i+=1
if !i! gtr !file_count! goto TRANSLATE_DONE

set "src=!file[%i%]!"
for %%F in ("!src!") do (
    set "src_path=%%~dpF"
    set "src_name=%%~nF"
)

echo.
echo  [TRANSLATE] Processing: !src_name!
echo.

"%DP%faster-whisper-xxl.exe" !TRANSLATE_FLAGS! "!src!"
color 0A

if exist "!src_path!!src_name!.srt" (
    move /y "!src_path!!src_name!.srt" "!src_path!!src_name!.EN.srt" >nul
    echo.
    echo  Starting German translation via Ollama ...
    echo.
    python "%DP%translate_srt.py" "!src_path!!src_name!.EN.srt" "!src_path!!src_name!.DE.srt" !CTX!
)
if exist "!src_path!!src_name!.DE.srt" echo  German translation created successfully.
if not exist "!src_path!!src_name!.DE.srt" echo  [ERROR] German translation failed.

if exist "!src_path!!src_name!.json" move /y "!src_path!!src_name!.json" "!src_path!!src_name!.EN.json" >nul
for %%W in ("!src_path!!src_name!*.wav") do del "%%W"
for %%J in ("!src_path!!src_name!*.json") do del "%%J"

goto TRANSLATE_LOOP

:TRANSLATE_DONE
goto END

:: ============================================================
::  [6] BACKGROUND EXTRACTION
:: ============================================================
:MODE_BACKGROUND
set "BG_FLAGS=--beep_off -pp -o source --standard -f srt -m tiny --ff_vocal_extract mdx_kim2 --ff_dump --mdx_chunk 1536 --print_progress"

set "i=0"
:BACKGROUND_LOOP
set /a i+=1
if !i! gtr !file_count! goto END

set "src=!file[%i%]!"
for %%F in ("!src!") do (
    set "src_path=%%~dpF"
    set "src_name=%%~nF"
    set "src_fullname=%%~nxF"
)

echo.
echo  [BACKGROUND] Processing: !src_name!
echo.

ffmpeg -y -v error -stats -i "!src!" -vn -ac 2 -ar 44100 "!src_path!!src_name!.original.wav"

"%DP%faster-whisper-xxl.exe" !BG_FLAGS! "!src!"
color 0A

set "VOX_FILE=!src_path!!src_fullname!_mdx1.wav"

if exist "!VOX_FILE!" (
    echo.
    echo  Running final vocal elimination ...
    ffmpeg -y -v error -stats -i "!src_path!!src_name!.original.wav" -i "!VOX_FILE!" -filter_complex "[1:a]volume=15,bandpass=f=1500:width_type=h:w=3000[sc];[0:a][sc]sidechaincompress=threshold=0.007:ratio=20:attack=2:release=450:knee=1" -c:a pcm_s16le "!src_path!!src_name!.background.wav"
    del "!src_path!!src_name!.original.wav"
    del "!src_path!!src_name!.srt"
    del "!VOX_FILE!"
    if exist "!src_path!!src_fullname!_dump.wav" del "!src_path!!src_fullname!_dump.wav"
)

goto BACKGROUND_LOOP

:: ============================================================
::  SRT DIRECT TRANSLATION  (SRT dropped onto script)
:: ============================================================
:MODE_SRT_TRANSLATE
call :ASK_CONTEXT
if /i "!CTX!"=="E" goto CLEANUP_EXIT
echo.
echo  [SRT-TRANSLATE] Checking Ollama ...
echo.
call :OLLAMA_SETUP

set "i=0"
:SRT_LOOP
set /a i+=1
if !i! gtr !file_count! goto SRT_DONE

set "src=!file[%i%]!"
for %%F in ("!src!") do (
    set "srt_path=%%~dpF"
    set "srt_base=%%~nF"
)

:: video.EN.srt -> video.DE.srt  |  video.srt -> video.DE.srt
set "out_base=!srt_base!"
if /i "!srt_base:~-3!"==".EN" set "out_base=!srt_base:~0,-3!"
set "out_file=!srt_path!!out_base!.DE.srt"

echo.
echo  Translating: !srt_base!.srt  --^>  !out_base!.DE.srt
echo.

python "%DP%translate_srt.py" "!src!" "!out_file!" !CTX!

if exist "!out_file!" echo  German translation created successfully.
if not exist "!out_file!" echo  [ERROR] Translation failed.

goto SRT_LOOP

:SRT_DONE
goto END

:: ============================================================
::  Subroutine: Ask for context block count
:: ============================================================
:ASK_CONTEXT
echo.
echo  -------------------------------------------------------
echo   Context blocks for translation:
echo  -------------------------------------------------------
echo.
echo   Key  Benefit                        Speed
echo   ---  -----------------------------  --------------
echo   0    No context                     Fastest
echo   1    Minimal coherence              Very fast
echo   2    Consistent names and address   Fast
echo   3    Good compromise                Moderate     ^<-- Default
echo   5    Very consistent style          Slow
echo.
choice /c 012345E /n /m "  Context blocks [0-5, E = Abort]: "
if errorlevel 7 (set "CTX=E"  & exit /b)
if errorlevel 6 (set "CTX=5"  & exit /b)
if errorlevel 5 (set "CTX=4"  & exit /b)
if errorlevel 4 (set "CTX=3"  & exit /b)
if errorlevel 3 (set "CTX=2"  & exit /b)
if errorlevel 2 (set "CTX=1"  & exit /b)
if errorlevel 1 (set "CTX=0"  & exit /b)
exit /b

:: ============================================================
::  Subroutine: Check Ollama prerequisites
:: ============================================================
:OLLAMA_SETUP

:: --- Install Ollama if missing ---
where ollama >nul 2>nul
if errorlevel 1 (
    echo  Ollama not found. Downloading installer ...
    curl -L https://ollama.com/download/OllamaSetup.exe -o "%temp%\OllamaSetup.exe"
    echo  Installing Ollama ...
    start /wait "" "%temp%\OllamaSetup.exe" /silent
    set "PATH=%PATH%;%LocalAppData%\Programs\Ollama"
    timeout /t 3 >nul
)

:: --- Ollama environment variables (inherited by server process) ---
set "OLLAMA_HOST=127.0.0.1"
set "OLLAMA_FLASH_ATTENTION=1"
set "OLLAMA_KV_CACHE_TYPE=q4_0"
set "OLLAMA_GPU_OVERHEAD=0"
set "OLLAMA_NUM_PARALLEL=1"
set "OLLAMA_LOG_LEVEL=error"
set "OLLAMA_NUM_THREADS=8"

:: --- Check Python requests ---
python -c "import requests" >nul 2>nul
if errorlevel 1 pip install requests

exit /b

:: ============================================================
::  JSON cleanup for modes 1-4
:: ============================================================
:CLEANUP_JSON
set "ci=0"
:CLEANUP_JSON_LOOP
set /a ci+=1
if !ci! gtr !file_count! goto END
set "csrc=!file[%ci%]!"
for %%F in ("!csrc!") do (
    set "cpath=%%~dpF"
    set "cname=%%~nF"
)
for %%J in ("!cpath!!cname!*.json") do if exist "%%J" del "%%J" >nul 2>&1
goto CLEANUP_JSON_LOOP

:: ============================================================
::  Abort with optional WAV cleanup
:: ============================================================
:CLEANUP_EXIT
set "ci=0"
:CLEANUP_EXIT_LOOP
set /a ci+=1
if !ci! gtr !file_count! goto END
set "csrc=!file[%ci%]!"
for %%F in ("!csrc!") do (
    set "cpath=%%~dpF"
    set "cname=%%~nF"
)
set "cname_clean=!cname!"
if /i "!cname:~-3!"==".EN" set "cname_clean=!cname:~0,-3!"
for %%W in ("!cpath!!cname_clean!*.wav") do if exist "%%W" del "%%W" >nul 2>&1
goto CLEANUP_EXIT_LOOP

:: ============================================================
::  End
:: ============================================================
:END
echo.
color 0A
pause
color
exit /b
