@echo off
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

:: Default translation model (context option B switches to translategemma:12b)
set "MODEL=mistral-nemo"

:: Save extension of first file BEFORE shift consumes the args
set "_ext=%~x1"

:: Directory dropped? (batch mode handles skipping itself via --skip)
set "IS_DIR=0"
if exist "%~1\" set "IS_DIR=1"

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
set "COMMON=--beep_off -pp -o source --batch_recursive --skip --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
call :BUILD_WORKLIST
echo.
echo  [AUTO] Starting transcription (language auto-detect) ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% !todo_list!
if errorlevel 1 goto TRANSCRIBE_FAIL
call :CHECK_OUTPUT
goto CLEANUP_JSON

:: ============================================================
::  [2] AUTO + DIARIZE
:: ============================================================
:MODE_DIARIZE
set "COMMON=--beep_off -pp -o source --batch_recursive --skip --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
call :BUILD_WORKLIST
echo.
echo  [DIARIZE] Starting transcription with speaker recognition ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% !todo_list! --diarize pyannote_v3.1 --diarize_device cuda
if errorlevel 1 goto TRANSCRIBE_FAIL
call :CHECK_OUTPUT
goto CLEANUP_JSON

:: ============================================================
::  [3] GERMAN
:: ============================================================
:MODE_DE
set "COMMON=--beep_off -pp -o source --batch_recursive --skip --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
call :BUILD_WORKLIST
echo.
echo  [DE] Starting transcription in German ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% !todo_list! --language de
if errorlevel 1 goto TRANSCRIBE_FAIL
call :CHECK_OUTPUT
goto CLEANUP_JSON

:: ============================================================
::  [4] ENGLISH
:: ============================================================
:MODE_EN
set "COMMON=--beep_off -pp -o source --batch_recursive --skip --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
call :BUILD_WORKLIST
echo.
echo  [EN] Starting transcription in English ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% !todo_list! --language en
if errorlevel 1 goto TRANSCRIBE_FAIL
call :CHECK_OUTPUT
goto CLEANUP_JSON

:: ============================================================
::  Error handling for transcription modes
:: ============================================================
:TRANSCRIBE_FAIL
set "fail_code=!errorlevel!"
echo.
echo  [ERROR] Transcription failed - exit code !fail_code!
echo.
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
set "src_path="
set "src_name="
for %%F in ("!src!") do (
    set "src_path=%%~dpF"
    set "src_name=%%~nF"
)

echo.
echo  [TRANSLATE] Processing: !src_name!
echo.

"%DP%faster-whisper-xxl.exe" !TRANSLATE_FLAGS! "!src!"
if errorlevel 1 (
    echo  [ERROR] Whisper translation failed - exit code !errorlevel!
    goto TRANSLATE_NEXT
)

if not exist "!src_path!!src_name!.srt" (
    echo  [ERROR] No English subtitle produced: !src_name!.srt
    goto TRANSLATE_NEXT
)

move /y "!src_path!!src_name!.srt" "!src_path!!src_name!.EN.srt" >nul
if exist "!src_path!!src_name!.DE.srt" del "!src_path!!src_name!.DE.srt" >nul 2>&1
echo.
echo  Starting German translation via Ollama ...
echo.
python "%DP%translate_srt.py" "!src_path!!src_name!.EN.srt" "!src_path!!src_name!.DE.srt" !CTX! "!MODEL!"
if errorlevel 1 (
    echo  [ERROR] German translation failed - exit code !errorlevel!
    goto TRANSLATE_NEXT
)
if exist "!src_path!!src_name!.DE.srt" (
    echo  [OK] German translation created: !src_name!.DE.srt
) else (
    echo  [ERROR] German translation failed - no output written.
)

:TRANSLATE_NEXT
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
set "BG_FLAGS=--beep_off -pp -o source --standard -f srt -m tiny --ff_vocal_extract mdx_kim2 --ff_dump --mdx_chunk 15 --print_progress"

set "i=0"
:BACKGROUND_LOOP
set /a i+=1
if !i! gtr !file_count! goto END

set "src=!file[%i%]!"
set "src_path="
set "src_name="
set "src_fullname="
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
if errorlevel 1 (
    echo  [ERROR] Audio separation failed - exit code !errorlevel!
    goto BACKGROUND_NEXT
)

set "VOX_FILE=!src_path!!src_fullname!_mdx1.wav"

if not exist "!VOX_FILE!" (
    echo  [ERROR] No vocal file produced: !src_fullname!_mdx1.wav
    goto BACKGROUND_NEXT
)

echo.
echo  Running final vocal elimination ...
ffmpeg -y -v error -stats -i "!src_path!!src_name!.original.wav" -i "!VOX_FILE!" -filter_complex "[1:a]volume=15,bandpass=f=1500:width_type=h:w=3000[sc];[0:a][sc]sidechaincompress=threshold=0.007:ratio=20:attack=2:release=450:knee=1" -c:a pcm_s16le "!src_path!!src_name!.background.wav"
if errorlevel 1 (
    echo  [ERROR] Background extraction failed - exit code !errorlevel!
    goto BACKGROUND_NEXT
)

del "!src_path!!src_name!.original.wav" >nul 2>&1
del "!src_path!!src_name!.srt" >nul 2>&1
del "!VOX_FILE!" >nul 2>&1
if exist "!src_path!!src_fullname!_dump.wav" del "!src_path!!src_fullname!_dump.wav" >nul 2>&1
echo  [OK] Background file created: !src_name!.background.wav

:BACKGROUND_NEXT
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
set "srt_path="
set "srt_base="
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

if exist "!out_file!" del "!out_file!" >nul 2>&1
python "%DP%translate_srt.py" "!src!" "!out_file!" !CTX! "!MODEL!"
if errorlevel 1 (
    echo  [ERROR] Translation failed - exit code !errorlevel!
) else (
    if exist "!out_file!" (
        echo  [OK] German translation created: !out_base!.DE.srt
    ) else (
        echo  [ERROR] Translation failed - no output written.
    )
)
goto SRT_LOOP

:SRT_DONE
goto END

:: ============================================================
::  Subroutine: build work list (skip files with existing subtitle)
:: ============================================================
:BUILD_WORKLIST
set "todo_list="
set "todo_count=0"
set "skip_count=0"
if "!IS_DIR!"=="1" (
    set "todo_list=!file_list!"
    set "todo_count=!file_count!"
    exit /b
)
set "bi=0"
:WORKLIST_LOOP
set /a bi+=1
if !bi! gtr !file_count! goto WORKLIST_READY
set "bf=!file[%bi%]!"
set "bfp="
set "bfn="
for %%F in ("!bf!") do (
    set "bfp=%%~dpF"
    set "bfn=%%~nF"
)
if exist "!bfp!!bfn!.srt" (
    echo  [SKIP] Subtitle already exists: !bfn!.srt
    set /a skip_count+=1
    goto WORKLIST_LOOP
)
set /a todo_count+=1
set "todo[!todo_count!]=!bf!"
set "todo_list=!todo_list! "!bf!""
goto WORKLIST_LOOP

:WORKLIST_READY
if !todo_count!==0 (
    echo.
    echo  Nothing to do - all dropped files already have a subtitle.
    echo.
    goto END
)
exit /b

:: ============================================================
::  Subroutine: verify that a subtitle was written for every file
:: ============================================================
:CHECK_OUTPUT
if "!IS_DIR!"=="1" exit /b
set "ci2=0"
:CHECK_OUTPUT_LOOP
set /a ci2+=1
if !ci2! gtr !todo_count! exit /b
set "cf=!todo[%ci2%]!"
set "cfp="
set "cfn="
for %%F in ("!cf!") do (
    set "cfp=%%~dpF"
    set "cfn=%%~nF"
)
if not exist "!cfp!!cfn!.srt" echo  [ERROR] No subtitle written: !cfn!.srt
goto CHECK_OUTPUT_LOOP

:: ============================================================
::  Subroutine: ask for context block count
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
echo   3    Good compromise                Moderate
echo   A    Full entity tracking (Mistral) Slowest
echo   B    Full entity tracking (Gemma)   Best
echo.
choice /c 03ABE /n /m "  Context blocks [0, 3, A = 10, B = 10, E = Abort]: "
if errorlevel 5 (set "CTX=E"  & exit /b)
if errorlevel 4 (set "CTX=10" & set "MODEL=translategemma:12b" & exit /b)
if errorlevel 3 (set "CTX=10" & exit /b)
if errorlevel 2 (set "CTX=3"  & exit /b)
if errorlevel 1 (set "CTX=0"  & exit /b)
exit /b

:: ============================================================
::  Subroutine: check Ollama / Python prerequisites
:: ============================================================
:OLLAMA_SETUP

:: --- Python is required for the Ollama translation ---
where python >nul 2>nul
if errorlevel 1 (
    echo  [ERROR] Python not found in PATH - required for the Ollama translation.
    echo          Install Python 3.x and make sure "python" is available.
    goto END
)

:: --- Install Ollama if missing ---
where ollama >nul 2>nul
if errorlevel 1 (
    echo  Ollama not found. Downloading installer ...
    curl -L https://ollama.com/download/OllamaSetup.exe -o "%temp%\OllamaSetup.exe"
    if errorlevel 1 (
        echo  [ERROR] Ollama download failed - check your internet connection.
        goto END
    )
    echo  Installing Ollama ...
    start /wait "" "%temp%\OllamaSetup.exe" /silent
    if errorlevel 1 echo  [WARNING] Ollama installer returned an error.
    set "PATH=!PATH!;!LOCALAPPDATA!\Programs\Ollama"
    timeout /t 3 >nul
    where ollama >nul 2>nul
    if errorlevel 1 (
        echo  [ERROR] Ollama is not available - please install it manually.
        goto END
    )
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
if errorlevel 1 (
    echo  Installing Python package "requests" ...
    python -m pip install requests
    if errorlevel 1 (
        echo  [ERROR] Could not install "requests" - translation will not work.
        goto END
    )
)

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
pause
exit /b
