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

:: Subtitle suffix of the selected mode (mode 3 = .DE.srt, mode 4 = .EN.srt)
set "OUTSUFFIX=.srt"
set "WORKLIST_EMPTY="
set "ERRLOG=%TEMP%\faster-whisper-stderr.log"
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1

:: Save extension of first file BEFORE shift consumes the args
set "_ext=%~x1"

:: Directory dropped? (batch mode handles skipping itself via --skip)
set "IS_DIR=0"
pushd "%~1" 2>nul
if not errorlevel 1 (
    set "IS_DIR=1"
    set "DIR_PATH=%~1"
    popd
)

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
:MAIN_MENU
cls
echo.
echo      8""""                                    8   8  8                                       8   8 8   8 8
echo      8     eeeee eeeee eeeee eeee eeeee       8   8  8 e   e e  eeeee eeeee eeee eeeee        8 8   8 8  8
echo      8eeee 8   8 8   "   8   8    8   8       8e  8  8 8   8 8  8   " 8   8 8    8   8        eee   eee  8e
echo      88    8eee8 8eeee   8e  8eee 8eee8e eeee 88  8  8 8eee8 8e 8eeee 8eee8 8eee 8eee8e eeee 88  8 88  8 88
echo      88    88  8    88   88  88   88   8      88  8  8 88  8 88    88 88    88   88   8      88  8 88  8 88
echo      88    88  8 8ee88   88  88ee 88   8      88ee8ee8 88  8 88 8ee88 88    88ee 88   8      88  8 88  8 88eee
echo.
echo  !file_count! file(s) loaded.
set "li=0"
:FILE_LIST_LOOP
set /a li+=1
if !li! gtr !file_count! goto FILE_LIST_DONE
set "lf=!file[%li%]!"
for %%F in ("!lf!") do set "lfn=%%~nxF"
echo   - !lfn!
goto FILE_LIST_LOOP
:FILE_LIST_DONE
echo.
echo  -------------------------------------------------------
echo   What do you want to do?
echo  -------------------------------------------------------
echo.
echo   [1]  Transcribe AUTO          (language auto-detect)
echo   [2]  Transcribe AUTO+DIARIZE  (speaker recognition)
echo   [3]  Transcribe GERMAN        (language forced)
echo   [4]  Transcribe ENGLISH       (language forced)
echo   [5]  Translate GERMAN         (Whisper DE, Ollama to EN)
echo   [6]  Translate ENGLISH        (Whisper EN, Ollama to DE)
echo   [7]  Background Extraction    (remove vocals)
echo.
choice /c 1234567E /n /m "  Select [1-7, E = Exit]: "
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER

if errorlevel 8 goto END
if errorlevel 7 goto MODE_BACKGROUND
if errorlevel 6 goto MODE_TRANSLATE_EN
if errorlevel 5 goto MODE_TRANSLATE_DE
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
if defined WORKLIST_EMPTY goto END
echo.
echo [FAST-WHISPER] Starting transcription (language auto-detect) ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% !todo_list! 2>>"!ERRLOG!"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
if errorlevel 1 goto TRANSCRIBE_FAIL
if exist "!ERRLOG!" type "!ERRLOG!"
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
call :RENAME_OUTPUT
call :CHECK_OUTPUT
goto CLEANUP_JSON

:: ============================================================
::  [2] AUTO + DIARIZE
:: ============================================================
:MODE_DIARIZE
set "COMMON=--beep_off -pp -o source --batch_recursive --skip --check_files --standard -f json srt -m large-v2 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
call :BUILD_WORKLIST
if defined WORKLIST_EMPTY goto END
echo.
echo [FAST-WHISPER] Starting transcription with speaker recognition ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% !todo_list! --diarize pyannote_v3.1 --diarize_device cuda 2>>"!ERRLOG!"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
if errorlevel 1 goto TRANSCRIBE_FAIL
if exist "!ERRLOG!" type "!ERRLOG!"
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
call :RENAME_OUTPUT
call :CHECK_OUTPUT
goto CLEANUP_JSON

:: ============================================================
::  Modes 3/4/5/6: reuse existing DE/EN subtitles where possible
:: ============================================================
:MODE_DE
set "LANG=de" & set "LANG_NAME=German" & set "OUT_SUFFIX=.DE.srt" & set "OTHER_SUFFIX=.EN.srt" & set "OTHER_LANG=en" & set "OTHER_NAME=English" & set "NEED_BOTH=0"
goto MODE_SRTCHECK

:: ============================================================
:MODE_EN
set "LANG=en" & set "LANG_NAME=English" & set "OUT_SUFFIX=.EN.srt" & set "OTHER_SUFFIX=.DE.srt" & set "OTHER_LANG=de" & set "OTHER_NAME=German" & set "NEED_BOTH=0"
goto MODE_SRTCHECK

:: ============================================================
:MODE_TRANSLATE_DE
set "LANG=de" & set "LANG_NAME=German" & set "OUT_SUFFIX=.DE.srt" & set "OTHER_SUFFIX=.EN.srt" & set "OTHER_LANG=en" & set "OTHER_NAME=English" & set "NEED_BOTH=1"
goto MODE_SRTCHECK

:: ============================================================
:MODE_TRANSLATE_EN
set "LANG=en" & set "LANG_NAME=English" & set "OUT_SUFFIX=.EN.srt" & set "OTHER_SUFFIX=.DE.srt" & set "OTHER_LANG=de" & set "OTHER_NAME=German" & set "NEED_BOTH=1"
goto MODE_SRTCHECK

:: ============================================================
:MODE_SRTCHECK
if "!IS_DIR!"=="1" call :EXPAND_DIR
if "!IS_DIR!"=="1" if !file_count!==0 (
    echo.
    echo [FAST-WHISPER] No supported media files found in the dropped folder.
    echo.
    goto END
)
set "did_work="
set "wcount=0"
set "whisper_list="
set "job_count=0"
set "JOBFILE=%TEMP%\faster-whisper-jobs.txt"
if exist "!JOBFILE!" del "!JOBFILE!" >nul 2>&1
set "i=0"
:MODE_SRTCHECK_LOOP
set /a i+=1
if !i! gtr !file_count! goto MODE_SRTCHECK_RUN

set "src=!file[%i%]!"
set "src_path="
set "src_name="
for %%F in ("!src!") do (
    set "src_path=%%~dpF"
    set "src_name=%%~nF"
)

set "exist_out=0"
if exist "!src_path!!src_name!!OUT_SUFFIX!" set "exist_out=1"
set "exist_other=0"
if exist "!src_path!!src_name!!OTHER_SUFFIX!" set "exist_other=1"

if "!exist_out!"=="1" if "!exist_other!"=="1" (
    echo [FAST-WHISPER] Subtitles already exist: !src_name!!OUT_SUFFIX! + !src_name!!OTHER_SUFFIX!
    goto MODE_SRTCHECK_NEXT
)
if "!exist_out!"=="1" if "!NEED_BOTH!"=="0" (
    echo [FAST-WHISPER] Subtitle already exists: !src_name!!OUT_SUFFIX!
    goto MODE_SRTCHECK_NEXT
)

if "!exist_out!"=="1" (
    call :ADD_JOB "!src_path!!src_name!!OUT_SUFFIX!" "!src_path!!src_name!!OTHER_SUFFIX!" !OTHER_LANG!
    goto MODE_SRTCHECK_NEXT
)
if "!exist_other!"=="1" (
    call :ADD_JOB "!src_path!!src_name!!OTHER_SUFFIX!" "!src_path!!src_name!!OUT_SUFFIX!" !LANG!
    goto MODE_SRTCHECK_NEXT
)

set /a wcount+=1
set "wfile[!wcount!]=!src!"
set "whisper_list=!whisper_list! "!src!""
if "!NEED_BOTH!"=="1" call :ADD_JOB "!src_path!!src_name!!OUT_SUFFIX!" "!src_path!!src_name!!OTHER_SUFFIX!" !OTHER_LANG!

:MODE_SRTCHECK_NEXT
goto MODE_SRTCHECK_LOOP

:MODE_SRTCHECK_RUN
if !job_count! gtr 0 (
    call :ASK_CONTEXT
    if /i "!CTX!"=="C" goto CANCELLED_BY_USER
    if /i "!CTX!"=="R" goto MAIN_MENU
    if /i "!CTX!"=="E" goto CLEANUP_EXIT
)

set "LANG_FLAGS=--beep_off -pp -o source --standard -f srt -m large-v2 --language !LANG! --ff_vocal_extract mdx_kim2 --ff_dump --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"

set "whisper_done="
if !wcount! gtr 0 (
    echo.
    echo [FAST-WHISPER] Starting transcription in !LANG_NAME! - !wcount! files ...
    echo.
    "%DP%faster-whisper-xxl.exe" !LANG_FLAGS! !whisper_list! 2>>"!ERRLOG!"
    if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
    if errorlevel 1 (
        echo [FAST-WHISPER] Whisper transcription failed - exit code !errorlevel!
        if exist "!ERRLOG!" type "!ERRLOG!"
        if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
        goto MODE_SRTCHECK_TRANSLATE
    )
    if exist "!ERRLOG!" type "!ERRLOG!"
    if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
    set "did_work=1"
    set "whisper_done=1"
)
if not defined whisper_done goto MODE_SRTCHECK_TRANSLATE

set "wi=0"
:RENAME_WHISPER_LOOP
set /a wi+=1
if !wi! gtr !wcount! goto MODE_SRTCHECK_TRANSLATE
set "wf=!wfile[%wi%]!"
set "wpath="
set "wname="
for %%F in ("!wf!") do (
    set "wpath=%%~dpF"
    set "wname=%%~nF"
)
if exist "!wpath!!wname!.srt" (
    move /y "!wpath!!wname!.srt" "!wpath!!wname!!OUT_SUFFIX!" >nul
) else (
    echo [FAST-WHISPER] No subtitle produced: !wname!.srt
)
goto RENAME_WHISPER_LOOP

:MODE_SRTCHECK_TRANSLATE
if !job_count! gtr 0 (
    echo.
    echo [FAST-WHISPER] Checking Ollama ...
    call :OLLAMA_SETUP
    python "%DP%translate_srt.py" --batch "!JOBFILE!" !CTX! "!MODEL!"
    if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
    if errorlevel 1 (
        echo [FAST-WHISPER] Translation failed - exit code !errorlevel!
        goto MODE_SRTCHECK_CLEANUP
    )
    set "did_work=1"
)

:MODE_SRTCHECK_CLEANUP
set "ci=0"
:MODE_SRTCHECK_CLEAN_LOOP
set /a ci+=1
if !ci! gtr !file_count! goto MODE_SRTCHECK_DONE
set "cf=!file[%ci%]!"
set "cpath="
set "cname="
for %%F in ("!cf!") do (
    set "cpath=%%~dpF"
    set "cname=%%~nF"
)
if exist "!cpath!!cname!.json" del "!cpath!!cname!.json" >nul 2>&1
for %%W in ("!cpath!!cname!*.wav") do if exist "%%W" del "%%W" >nul 2>&1
goto MODE_SRTCHECK_CLEAN_LOOP

:MODE_SRTCHECK_DONE
if exist "!JOBFILE!" del "!JOBFILE!" >nul 2>&1
if not defined did_work (
    echo.
    echo [FAST-WHISPER] Nothing to do - all dropped files already have subtitles.
    echo.
)
goto END

:: ============================================================
::  Subroutine: append one translation job
:: ============================================================
:ADD_JOB
set /a job_count+=1
>>"!JOBFILE!" echo "%~1"^|"%~2"^|%~3
exit /b

:: ============================================================
::  Subroutine: expand dropped folder into media files
:: ============================================================
:EXPAND_DIR
set "file_count=0"
pushd "!DIR_PATH!"
for /r %%F in (*) do (
    set "fext=%%~xF"
    set "ismedia="
    for %%E in (.mp4 .mkv .m4v .mov .avi .webm .wmv .flv .mpg .mpeg .ts .m2ts .mts .vob .3gp .ogv .mp3 .wav .m4a .aac .flac .ogg .opus .wma .aiff .aif .m4b .caf .amr .wv .ape) do (
        if /i "!fext!"=="%%E" set "ismedia=1"
    )
    if defined ismedia (
        set /a file_count+=1
        set "file[!file_count!]=%%F"
    )
)
popd
exit /b
::  Error handling for transcription modes
:: ============================================================
:TRANSCRIBE_FAIL
set "fail_code=!errorlevel!"
echo.
echo [FAST-WHISPER] Transcription failed - exit code !fail_code!
if exist "!ERRLOG!" type "!ERRLOG!"
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
echo.
goto CLEANUP_JSON



:: ============================================================
::  [7] BACKGROUND EXTRACTION
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
echo [FAST-WHISPER] Processing: !src_name!
echo.

ffmpeg -y -v error -stats -i "!src!" -vn -ac 2 -ar 44100 "!src_path!!src_name!.original.wav"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
echo.
"%DP%faster-whisper-xxl.exe" !BG_FLAGS! "!src!" 2>>"!ERRLOG!"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
if errorlevel 1 (
    echo [FAST-WHISPER] Audio separation failed - exit code !errorlevel!
    if exist "!ERRLOG!" type "!ERRLOG!"
    if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
    goto BACKGROUND_NEXT
)
if exist "!ERRLOG!" type "!ERRLOG!"
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1

set "VOX_FILE=!src_path!!src_fullname!_mdx1.wav"

if not exist "!VOX_FILE!" (
    echo [FAST-WHISPER] No vocal file produced: !src_fullname!_mdx1.wav
    goto BACKGROUND_NEXT
)

echo.
echo [FAST-WHISPER] Running final vocal elimination ...
ffmpeg -y -v error -stats -i "!src_path!!src_name!.original.wav" -i "!VOX_FILE!" -filter_complex "[1:a]volume=15,bandpass=f=1500:width_type=h:w=3000[sc];[0:a][sc]sidechaincompress=threshold=0.007:ratio=20:attack=2:release=450:knee=1" -c:a pcm_s16le "!src_path!!src_name!.background.wav"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
if errorlevel 1 (
    echo [FAST-WHISPER] Background extraction failed - exit code !errorlevel!
    goto BACKGROUND_NEXT
)

del "!src_path!!src_name!.original.wav" >nul 2>&1
del "!src_path!!src_name!.srt" >nul 2>&1
del "!VOX_FILE!" >nul 2>&1
if exist "!src_path!!src_fullname!_dump.wav" del "!src_path!!src_fullname!_dump.wav" >nul 2>&1
echo [FAST-WHISPER] Background file created: !src_name!.background.wav

:BACKGROUND_NEXT
goto BACKGROUND_LOOP

:: ============================================================
::  SRT DIRECT TRANSLATION  (SRT dropped onto script)
:: ============================================================
:MODE_SRT_TRANSLATE
call :ASK_CONTEXT
if /i "!CTX!"=="C" goto CANCELLED_BY_USER
if /i "!CTX!"=="R" goto MAIN_MENU
if /i "!CTX!"=="E" goto CLEANUP_EXIT

set "JOBFILE=%TEMP%\faster-whisper-jobs.txt"
if exist "!JOBFILE!" del "!JOBFILE!" >nul 2>&1
set "job_count=0"
set "i=0"
:SRT_LOOP
set /a i+=1
if !i! gtr !file_count! goto SRT_RUN

set "src=!file[%i%]!"
set "srt_path="
set "srt_base="
for %%F in ("!src!") do (
    set "srt_path=%%~dpF"
    set "srt_base=%%~nF"
)
set "out_base=!srt_base!"
if /i "!srt_base:~-3!"==".EN" set "out_base=!srt_base:~0,-3!"
set "out_file=!srt_path!!out_base!.DE.srt"
if exist "!out_file!" del "!out_file!" >nul 2>&1
call :ADD_JOB "!src!" "!out_file!" de
goto SRT_LOOP

:SRT_RUN
if !job_count!==0 (
    echo.
    echo [FAST-WHISPER] Nothing to translate.
    echo.
    goto END
)
echo.
echo [FAST-WHISPER] Checking Ollama ...
call :OLLAMA_SETUP
python "%DP%translate_srt.py" --batch "!JOBFILE!" !CTX! "!MODEL!"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
if errorlevel 1 echo [FAST-WHISPER] Translation failed - exit code !errorlevel!
if exist "!JOBFILE!" del "!JOBFILE!" >nul 2>&1
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
if exist "!bfp!!bfn!!OUTSUFFIX!" (
    echo [FAST-WHISPER] Subtitle already exists: !bfn!!OUTSUFFIX!
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
    echo [FAST-WHISPER] Nothing to do - all dropped files already have a subtitle.
    echo.
    set "WORKLIST_EMPTY=1"
    exit /b
)
exit /b

:: ============================================================
::  Subroutine: rename the subtitle to the mode-specific suffix
:: ============================================================
:RENAME_OUTPUT
if "!IS_DIR!"=="1" exit /b
if /i "!OUTSUFFIX!"==".srt" exit /b
set "ri=0"
:RENAME_OUTPUT_LOOP
set /a ri+=1
if !ri! gtr !todo_count! exit /b
set "rf=!todo[%ri%]!"
set "rfp="
set "rfn="
for %%F in ("!rf!") do (
    set "rfp=%%~dpF"
    set "rfn=%%~nF"
)
if exist "!rfp!!rfn!.srt" move /y "!rfp!!rfn!.srt" "!rfp!!rfn!!OUTSUFFIX!" >nul
goto RENAME_OUTPUT_LOOP

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
if not exist "!cfp!!cfn!!OUTSUFFIX!" echo [FAST-WHISPER] No subtitle written: !cfn!!OUTSUFFIX!
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
:CTX_INPUT
set "CTX_KEY="
set /p "CTX_KEY=  Context blocks [0, 3, A = 10, B = 10, E = Exit, R = Return, Enter = B]: "
if "%errorlevel%"=="-1073741510" (set "CTX=C" & exit /b)
if not defined CTX_KEY set "CTX_KEY=B"
if defined CTX_KEY set "CTX_KEY=!CTX_KEY: =!"
if /i "!CTX_KEY!"=="0" (set "CTX=0"  & exit /b)
if /i "!CTX_KEY!"=="3" (set "CTX=3"  & exit /b)
if /i "!CTX_KEY!"=="A" (set "CTX=10" & exit /b)
if /i "!CTX_KEY!"=="B" (set "CTX=10" & set "MODEL=translategemma:12b" & exit /b)
if /i "!CTX_KEY!"=="E" (set "CTX=E"  & exit /b)
if /i "!CTX_KEY!"=="R" (set "CTX=R"  & exit /b)
echo   Invalid choice - please enter 0, 3, A, B, E or R. Press Enter for B.
goto CTX_INPUT

:: ============================================================
::  Subroutine: check Ollama / Python prerequisites
:: ============================================================
:OLLAMA_SETUP

:: --- Python is required for the Ollama translation ---
where python >nul 2>nul
if errorlevel 1 (
    echo [FAST-WHISPER] Python not found in PATH - required for the Ollama translation.
    echo [FAST-WHISPER] Install Python 3.x and make sure "python" is available.
    goto END
)

:: --- Install Ollama if missing ---
where ollama >nul 2>nul
if errorlevel 1 (
    echo [FAST-WHISPER] Ollama not found. Downloading installer ...
    curl -L https://ollama.com/download/OllamaSetup.exe -o "%temp%\OllamaSetup.exe"
    if errorlevel 1 (
        echo [FAST-WHISPER] Ollama download failed - check your internet connection.
        goto END
    )
    echo [FAST-WHISPER] Installing Ollama ...
    start /wait "" "%temp%\OllamaSetup.exe" /silent
    if errorlevel 1 echo [FAST-WHISPER] Ollama installer returned an error.
    set "PATH=!PATH!;!LOCALAPPDATA!\Programs\Ollama"
    timeout /t 3 >nul
    where ollama >nul 2>nul
    if errorlevel 1 (
        echo [FAST-WHISPER] Ollama is not available - please install it manually.
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
    echo [FAST-WHISPER] Installing Python package "requests" ...
    python -m pip install requests
    if errorlevel 1 (
        echo [FAST-WHISPER] Could not install "requests" - translation will not work.
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
::  Exit with optional WAV cleanup
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
::  Cancelled by user
:: ============================================================
:CANCELLED_BY_USER
echo.
echo [FAST-WHISPER] Cancelled by user.
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
goto END

:: ============================================================
::  End
:: ============================================================
:END
echo.
pause
exit /b
