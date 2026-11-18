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

set "DP=%~dp0"

set "MODEL=mistral-nemo"

set "OUTSUFFIX=.srt"
set "WORKLIST_EMPTY="
set "ERRLOG=%TEMP%\faster-whisper-stderr.log"
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1

set "_ext=%~x1"

set "IS_DIR=0"
pushd "%~1" 2>nul
if not errorlevel 1 (
    set "IS_DIR=1"
    set "DIR_PATH=%~1"
    popd
)

set "file_list="
set "file_count=0"

:COLLECT
set /a file_count+=1
set "file[!file_count!]=%~1"
set "file_list=!file_list! "%~1""
shift
if not "%~1"=="" goto COLLECT

if /i "%_ext%"==".srt" goto MODE_SRT_TRANSLATE

:: ============================================================
::  Banner + Menu
:: ============================================================
:MAIN_MENU
set "HAS_MISSING_MODELS="
for %%M in (tiny base small medium large-v2 large-v3) do (
    call :IS_MODEL_COMPLETE %%M
    if errorlevel 1 set "HAS_MISSING_MODELS=1"
)
if defined HAS_MISSING_MODELS (
    set "MENU_KEYS=12345678E"
    set "MENU_PROMPT=  Select [1-8, E = Exit]: "
) else (
    set "MENU_KEYS=1234567E"
    set "MENU_PROMPT=  Select [1-7, E = Exit]: "
)
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
echo   [3]  Transcribe GERMAN        (Whisper DE, language forced)
echo   [4]  Transcribe ENGLISH       (Whisper DE, language forced)
echo   [5]  Translate GERMAN         (Whisper DE, translate to EN)
echo   [6]  Translate ENGLISH        (Whisper EN, translate to DE)
echo   [7]  Background Extraction    (remove vocals)
if defined HAS_MISSING_MODELS echo   [8]  Download Models          (shown only if a model is incomplete)
echo.
choice /c !MENU_KEYS! /n /m "!MENU_PROMPT!"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER

if defined HAS_MISSING_MODELS (
    if errorlevel 9 goto END
    if errorlevel 8 goto MODE_DOWNLOAD_MODELS
) else (
    if errorlevel 8 goto END
)
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
set "COMMON=--beep_off -pp -o source --batch_recursive --skip --check_files --standard -f json srt -m large-v2 --compute_type float16 --vad_method pyannote_v3 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
call :BUILD_WORKLIST
if defined WORKLIST_EMPTY goto END
call :ENSURE_WHISPER_MODEL large-v2
if errorlevel 1 goto WHISPER_MODEL_ABORT
echo.
echo [FAST-WHISPER] Starting transcription (language auto-detect) ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% !todo_list! 2>>"!ERRLOG!"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
if errorlevel 1 goto TRANSCRIBE_FAIL
if exist "!ERRLOG!" echo.
if exist "!ERRLOG!" findstr /v /i /c:"Matplotlib is building the font cache" "!ERRLOG!"
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
call :RENAME_OUTPUT
call :CHECK_OUTPUT
goto CLEANUP_JSON

:: ============================================================
::  [2] AUTO + DIARIZE
:: ============================================================
:MODE_DIARIZE
set "COMMON=--beep_off -pp -o source --batch_recursive --skip --check_files --standard -f json srt -m large-v2 --compute_type float16 --vad_method pyannote_v3 --ff_vocal_extract mdx_kim2 --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"
call :BUILD_WORKLIST
if defined WORKLIST_EMPTY goto END
call :ENSURE_WHISPER_MODEL large-v2
if errorlevel 1 goto WHISPER_MODEL_ABORT
echo.
echo [FAST-WHISPER] Starting transcription with speaker recognition ...
echo.
"%DP%faster-whisper-xxl.exe" %COMMON% !todo_list! --diarize pyannote_v3.1 --diarize_device cuda 2>>"!ERRLOG!"
if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
if errorlevel 1 goto TRANSCRIBE_FAIL
if exist "!ERRLOG!" echo.
if exist "!ERRLOG!" findstr /v /i /c:"Matplotlib is building the font cache" "!ERRLOG!"
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
call :CHECK_PYTHON
if errorlevel 1 goto CLEANUP_EXIT
set "LANG=de" & set "LANG_NAME=German" & set "OUT_SUFFIX=.DE.srt" & set "OTHER_SUFFIX=.EN.srt" & set "OTHER_LANG=en" & set "OTHER_NAME=English" & set "NEED_BOTH=1"
goto MODE_SRTCHECK

:: ============================================================
:MODE_TRANSLATE_EN
call :CHECK_PYTHON
if errorlevel 1 goto CLEANUP_EXIT
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

set "LANG_FLAGS=--beep_off -pp -o source --standard -f srt -m large-v2 --compute_type float16 --vad_method pyannote_v3 --language !LANG! --ff_vocal_extract mdx_kim2 --ff_dump --beam_size 5 --best_of 5 --chunk_length 30 --patience 2.0 --temperature 0.0 --compression_ratio_threshold 2.4 --no_speech_threshold 0.5 --word_timestamps true --condition_on_previous_text true --print_progress"

call :ENSURE_WHISPER_MODEL large-v2
if errorlevel 1 goto WHISPER_MODEL_ABORT

set "whisper_done="
if !wcount! gtr 0 (
    echo.
    echo [FAST-WHISPER] Starting transcription in !LANG_NAME! - !wcount! files ...
    echo.
    "%DP%faster-whisper-xxl.exe" !LANG_FLAGS! !whisper_list! 2>>"!ERRLOG!"
    if "%errorlevel%"=="-1073741510" goto CANCELLED_BY_USER
    if errorlevel 1 (
        echo [FAST-WHISPER] Whisper transcription failed - exit code !errorlevel!
        if exist "!ERRLOG!" echo.
        if exist "!ERRLOG!" findstr /v /i /c:"Matplotlib is building the font cache" "!ERRLOG!"
        if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
        goto MODE_SRTCHECK_TRANSLATE
    )
    if exist "!ERRLOG!" echo.
    if exist "!ERRLOG!" findstr /v /i /c:"Matplotlib is building the font cache" "!ERRLOG!"
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
    if errorlevel 1 goto CLEANUP_EXIT
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
:: ============================================================
::  Error handling for transcription modes
:: ============================================================
:TRANSCRIBE_FAIL
set "fail_code=!errorlevel!"
echo.
echo [FAST-WHISPER] Transcription failed - exit code !fail_code!
if exist "!ERRLOG!" echo.
if exist "!ERRLOG!" findstr /v /i /c:"Matplotlib is building the font cache" "!ERRLOG!"
if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
echo.
goto CLEANUP_JSON



:: ============================================================
::  [7] BACKGROUND EXTRACTION
:: ============================================================
:MODE_BACKGROUND
set "BG_FLAGS=--beep_off -pp -o source --standard -f srt -m tiny --ff_vocal_extract mdx_kim2 --ff_dump --mdx_chunk 15 --print_progress"
call :ENSURE_WHISPER_MODEL tiny
if errorlevel 1 goto WHISPER_MODEL_ABORT

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
    if exist "!ERRLOG!" echo.
    if exist "!ERRLOG!" findstr /v /i /c:"Matplotlib is building the font cache" "!ERRLOG!"
    if exist "!ERRLOG!" del "!ERRLOG!" >nul 2>&1
    goto BACKGROUND_NEXT
)
if exist "!ERRLOG!" echo.
if exist "!ERRLOG!" findstr /v /i /c:"Matplotlib is building the font cache" "!ERRLOG!"
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
call :CHECK_PYTHON
if errorlevel 1 goto CLEANUP_EXIT
set "JOBFILE=%TEMP%\faster-whisper-jobs.txt"
if exist "!JOBFILE!" del "!JOBFILE!" >nul 2>&1
set "job_count=0"
set "jcount=0"
set "i=0"
:SRT_LOOP
set /a i+=1
if !i! gtr !file_count! goto SRT_SCAN_DONE

set "src=!file[%i%]!"
set "srt_path="
set "srt_name="
for %%F in ("!src!") do (
    set "srt_path=%%~dpF"
    set "srt_name=%%~nxF"
)
set "stem=!srt_name!"
if /i "!stem:~-4!"==".srt" set "stem=!stem:~0,-4!"
set "base=!stem!"
set "ext="
for %%A in ("!stem!") do (
    set "base=%%~nA"
    set "ext=%%~xA"
)
if /i "!ext!"==".DE" (
    call :SRT_ADD_TARGET EN
    goto SRT_LOOP_NEXT
)
if /i "!ext!"==".EN" (
    call :SRT_ADD_TARGET DE
    goto SRT_LOOP_NEXT
)
call :CHECK_LANG_EXT
if defined LANGEXT (
    call :SRT_ADD_TARGET DE
    call :SRT_ADD_TARGET EN
) else (
    set "base=!stem!"
    call :SRT_ADD_TARGET DE
)
:SRT_LOOP_NEXT
goto SRT_LOOP

:SRT_ADD_TARGET
set "tgt=%~1"
set "tname=!base!.!tgt!.srt"
set "dst=!srt_path!!tname!"
if exist "!dst!" (
    echo [FAST-WHISPER] Subtitle already exists: !tname!
    exit /b
)
if /i "!tgt!"=="EN" if exist "!srt_path!!base!.srt" (
    echo [FAST-WHISPER] Subtitle already exists: !base!.srt - treated as English
    exit /b
)
set "dup="
set "di=0"
:SRT_DUP_LOOP
set /a di+=1
if !di! gtr !jcount! goto SRT_DUP_DONE
if /i "!jds[%di%]!"=="!dst!" set "dup=1"
goto SRT_DUP_LOOP
:SRT_DUP_DONE
if defined dup (
    echo [FAST-WHISPER] Duplicate target skipped: !tname!
    exit /b
)
set /a jcount+=1
set "jds[!jcount!]=!dst!"
if /i "!tgt!"=="EN" (
    call :ADD_JOB "!src!" "!dst!" en
) else (
    call :ADD_JOB "!src!" "!dst!" de
)
exit /b

:CHECK_LANG_EXT
set "LANGEXT="
set "el="
if "!ext:~0,1!"=="." set "el=!ext:~1!"
if not defined el exit /b
echo !el!|findstr /r "^[A-Za-z][A-Za-z]$" >nul && set "LANGEXT=1"
echo !el!|findstr /r "^[A-Za-z][A-Za-z][A-Za-z]$" >nul && set "LANGEXT=1"
exit /b

:SRT_SCAN_DONE
if !job_count!==0 (
    echo.
    echo [FAST-WHISPER] Nothing to do - all dropped files already have translations.
    echo.
    if exist "!JOBFILE!" del "!JOBFILE!" >nul 2>&1
    goto END
)
call :ASK_CONTEXT
if /i "!CTX!"=="C" goto CANCELLED_BY_USER
if /i "!CTX!"=="R" goto MAIN_MENU
if /i "!CTX!"=="E" goto CLEANUP_EXIT
echo.
echo [FAST-WHISPER] Checking Ollama ...
call :OLLAMA_SETUP
if errorlevel 1 goto CLEANUP_EXIT
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
set "have="
if exist "!bfp!!bfn!.srt" set "have=!bfn!.srt"
if exist "!bfp!!bfn!.DE.srt" set "have=!bfn!.DE.srt"
if exist "!bfp!!bfn!.EN.srt" set "have=!bfn!.EN.srt"
if not defined have if exist "!bfp!!bfn!.*.srt" set "have=!bfn!.*.srt"
if defined have (
    echo [FAST-WHISPER] Subtitle already exists: !have!
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
::  Subroutine: rename auto-detected subtitle by its language (de/en)
:: ============================================================
:RENAME_OUTPUT
if "!IS_DIR!"=="1" goto RENAME_DIR_OUTPUT
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
if not exist "!rfp!!rfn!.srt" goto RENAME_OUTPUT_LOOP
set "lang="
if exist "!rfp!!rfn!.json" (
    for /f "usebackq tokens=2 delims=:" %%L in (`findstr /i /c:language "!rfp!!rfn!.json"`) do (
        set "lv=%%L"
        set "lv=!lv: =!"
        for /f "tokens=1 delims=," %%M in ("!lv!") do set "lv=%%M"
        set "lv=!lv:"=!"
        set "lang=!lv!"
    )
)
call :TO_UPPER
if defined ULANG if exist "!rfp!!rfn!.srt" move /y "!rfp!!rfn!.srt" "!rfp!!rfn!.!ULANG!.srt" >nul
goto RENAME_OUTPUT_LOOP

:TO_UPPER
set "ULANG="
set "l1=!lang:~0,1!"
set "l2=!lang:~1,1!"
set "l3=!lang:~2,1!"
for %%C in (!l1! !l2! !l3!) do (
    for %%U in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
        if /i "%%C"=="%%U" set "ULANG=!ULANG!%%U"
    )
)
exit /b

:RENAME_DIR_OUTPUT
if not defined DIR_PATH exit /b
pushd "!DIR_PATH!"
for /r %%J in (*.json) do (
    set "dpath=%%~dpJ"
    set "dname=%%~nJ"
    set "dlang="
    for /f "usebackq tokens=2 delims=:" %%L in (`findstr /i /c:language "%%J"`) do (
        set "lv=%%L"
        set "lv=!lv: =!"
        for /f "tokens=1 delims=," %%M in ("!lv!") do set "lv=%%M"
        set "lv=!lv:"=!"
        set "dlang=!lv!"
    )
    set "lang=!dlang!"
    call :TO_UPPER
    if defined ULANG if exist "!dpath!!dname!.srt" move /y "!dpath!!dname!.srt" "!dpath!!dname!.!ULANG!.srt" >nul
)
popd
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
if exist "!cfp!!cfn!.srt" goto CHECK_OUTPUT_LOOP
if exist "!cfp!!cfn!.DE.srt" goto CHECK_OUTPUT_LOOP
if exist "!cfp!!cfn!.EN.srt" goto CHECK_OUTPUT_LOOP
echo [FAST-WHISPER] No subtitle written: !cfn!
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
echo   A    Full entity tracking (Mistral) Slow
echo   B    Full entity tracking (Gemma)   Slowest
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
::  Subroutine: check Python 3.x
:: ============================================================
:CHECK_PYTHON
where python >nul 2>nul
if errorlevel 1 goto PYTHON_MISSING
python -c "import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)" >nul 2>nul
if errorlevel 1 goto PYTHON_MISSING
exit /b

:PYTHON_MISSING
echo.
echo [FAST-WHISPER] No working Python 3.7+ found.
echo [FAST-WHISPER] translate_srt.py requires Python 3.7 or newer (3.10+ recommended).
echo [FAST-WHISPER] Please install Python: https://www.python.org/downloads/
echo [FAST-WHISPER] During setup enable "Add python.exe to PATH", then run again.
echo.
exit /b 1

:: ============================================================
::  Subroutine: check Ollama / Python prerequisites
:: ============================================================
:OLLAMA_SETUP

call :CHECK_PYTHON
if errorlevel 1 exit /b 1

where ollama >nul 2>nul
if errorlevel 1 (
    echo [FAST-WHISPER] Ollama not found. Downloading installer ...
    curl -L https://ollama.com/download/OllamaSetup.exe -o "%temp%\OllamaSetup.exe"
    if errorlevel 1 (
        echo [FAST-WHISPER] Ollama download failed - check your internet connection.
        exit /b 1
    )
    echo [FAST-WHISPER] Installing Ollama ...
    start /wait "" "%temp%\OllamaSetup.exe" /silent
    if errorlevel 1 echo [FAST-WHISPER] Ollama installer returned an error.
    set "PATH=!PATH!;!LOCALAPPDATA!\Programs\Ollama"
    timeout /t 3 >nul
    where ollama >nul 2>nul
    if errorlevel 1 (
        echo [FAST-WHISPER] Ollama is not available - please install it manually.
        exit /b 1
    )
)

set "OLLAMA_HOST=127.0.0.1"
set "OLLAMA_FLASH_ATTENTION=1"
set "OLLAMA_KV_CACHE_TYPE=q4_0"
set "OLLAMA_GPU_OVERHEAD=0"
set "OLLAMA_NUM_PARALLEL=1"
set "OLLAMA_LOG_LEVEL=error"
set "OLLAMA_NUM_THREADS=8"

python -c "import requests" >nul 2>nul
if errorlevel 1 (
    echo [FAST-WHISPER] Installing Python package "requests" ...
    python -m pip install requests
    if errorlevel 1 (
        echo [FAST-WHISPER] Could not install "requests" - translation will not work.
        exit /b 1
    )
)

exit /b

:: ============================================================
::  JSON cleanup for modes 1-4
:: ============================================================
:CLEANUP_JSON
if "!IS_DIR!"=="1" (
    if defined DIR_PATH (
        pushd "!DIR_PATH!"
        for /r %%J in (*.json) do del "%%J" >nul 2>&1
        popd
    )
    goto END
)
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
::  Subroutine: ensure a faster-whisper model exists (download from HF)
:: ============================================================
:GET_MODEL_FILES
set "MFILES="
if /i "%~1"=="tiny" set "MFILES=config.json model.bin tokenizer.json vocabulary.txt"
if /i "%~1"=="base" set "MFILES=config.json model.bin tokenizer.json vocabulary.txt"
if /i "%~1"=="small" set "MFILES=config.json model.bin tokenizer.json vocabulary.txt"
if /i "%~1"=="medium" set "MFILES=config.json model.bin tokenizer.json vocabulary.txt"
if /i "%~1"=="large-v2" set "MFILES=config.json model.bin tokenizer.json vocabulary.txt"
if /i "%~1"=="large-v3" set "MFILES=config.json model.bin tokenizer.json vocabulary.json preprocessor_config.json"
exit /b

:IS_FILE_OK
set "FF=%~1"
if not exist "!FF!" exit /b 1
for %%A in ("!FF!") do if %%~zA==0 exit /b 1
if /i "%~nx1"=="model.bin" for %%A in ("!FF!") do if %%~zA LSS 1048576 exit /b 1
exit /b 0

:IS_MODEL_COMPLETE
set "CMODEL=%~1"
set "CMODELDIR=%DP%_models\faster-whisper-!CMODEL!"
call :GET_MODEL_FILES !CMODEL!
if not defined MFILES exit /b 1
set "MCOMPLETE=1"
for %%F in (!MFILES!) do (
    call :IS_FILE_OK "!CMODELDIR!\%%F"
    if errorlevel 1 set "MCOMPLETE="
)
if not defined MCOMPLETE exit /b 1
exit /b 0

:DOWNLOAD_MODEL_FILE
set "DFILE=%~1"
if exist "!WMODELDIR!\!DFILE!" for %%A in ("!WMODELDIR!\!DFILE!") do if %%~zA GTR 0 exit /b 0
echo [FAST-WHISPER]   downloading !DFILE! ...
curl -L --fail -o "!WMODELDIR!\!DFILE!" "!WMODELURL!/!DFILE!"
if errorlevel 1 (
    echo [FAST-WHISPER]   download failed: !DFILE!
    if exist "!WMODELDIR!\!DFILE!" del "!WMODELDIR!\!DFILE!" >nul 2>&1
    exit /b 1
)
exit /b 0

:ENSURE_WHISPER_MODEL
set "WMODEL=%~1"
set "WMODELDIR=%DP%_models\faster-whisper-!WMODEL!"
set "WMODELURL=https://huggingface.co/Systran/faster-whisper-!WMODEL!/resolve/main"
call :IS_MODEL_COMPLETE !WMODEL!
if not errorlevel 1 exit /b 0
call :GET_MODEL_FILES !WMODEL!
if not defined MFILES (
    echo [FAST-WHISPER] Unknown Whisper model: !WMODEL!
    exit /b 1
)
echo.
echo [FAST-WHISPER] Whisper model "!WMODEL!" is incomplete - downloading ...
if not exist "%DP%_models\" mkdir "%DP%_models%" >nul 2>&1
if not exist "!WMODELDIR!\" mkdir "!WMODELDIR!" >nul 2>&1
set "MDLFAIL="
for %%F in (!MFILES!) do (
    call :DOWNLOAD_MODEL_FILE "%%F"
    if errorlevel 1 set "MDLFAIL=1"
)
if defined MDLFAIL (
    echo [FAST-WHISPER] Whisper model download failed: !WMODEL!
    exit /b 1
)
echo [FAST-WHISPER] Whisper model "!WMODEL!" ready.
exit /b 0
:MODE_DOWNLOAD_MODELS
echo.
echo [FAST-WHISPER] Checking faster-whisper models ...
set "DMFAIL=0"
for %%M in (tiny base small medium large-v2 large-v3) do (
    call :ENSURE_WHISPER_MODEL %%M
    if errorlevel 1 set "DMFAIL=1"
)
echo.
if "!DMFAIL!"=="1" (
    echo [FAST-WHISPER] Some models could not be downloaded - see messages above.
) else (
    echo [FAST-WHISPER] All faster-whisper models are available.
)
echo.
pause
goto MAIN_MENU

:WHISPER_MODEL_ABORT
echo.
echo [FAST-WHISPER] Whisper model is not available - aborting.
echo.
goto END

:: ============================================================
::  End
:: ============================================================
:END
echo.
pause
exit /b
