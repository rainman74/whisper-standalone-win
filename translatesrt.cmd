@echo off
setlocal enabledelayedexpansion

set "DP=%~dp0"

:: Default translation model (context option B switches to translategemma:12b)
set "MODEL=mistral-nemo"

if "%~1"=="" (
    echo.
    echo  No file detected.
    echo  Drop one or more SRT files onto this script.
    echo.
    pause
    exit /b
)

:: Collect all dropped SRT files
set "file_list="
set "file_count=0"
:COLLECT
set /a file_count+=1
set "file[!file_count!]=%~1"
shift
if not "%~1"=="" goto COLLECT

:: ============================================================
::  Build translation jobs (direction per file, skip existing)
:: ============================================================
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
set "base=!srt_name!"
set "target=DE"
if /i "!srt_name:~-7!"==".DE.srt" (
    set "base=!srt_name:~0,-7!"
    set "target=EN"
) else if /i "!srt_name:~-7!"==".EN.srt" (
    set "base=!srt_name:~0,-7!"
    set "target=DE"
) else (
    set "base=!srt_name:~0,-4!"
    set "target=DE"
)
set "dst=!srt_path!!base!.!target!.srt"
if exist "!dst!" (
    echo [FAST-WHISPER] Subtitle already exists: !base!.!target!.srt
    goto SRT_LOOP_NEXT
)
if /i "!target!"=="EN" if exist "!srt_path!!base!.srt" (
    echo [FAST-WHISPER] Subtitle already exists: !base!.srt - treated as English
    goto SRT_LOOP_NEXT
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
    echo [FAST-WHISPER] Duplicate target skipped: !base!.!target!.srt
    goto SRT_LOOP_NEXT
)
set /a jcount+=1
set "jds[!jcount!]=!dst!"
if /i "!target!"=="EN" (
    call :ADD_JOB "!src!" "!dst!" en
) else (
    call :ADD_JOB "!src!" "!dst!" de
)
:SRT_LOOP_NEXT
goto SRT_LOOP

:SRT_SCAN_DONE
if !job_count!==0 (
    echo.
    echo [FAST-WHISPER] Nothing to do - all dropped files already have translations.
    echo.
    if exist "!JOBFILE!" del "!JOBFILE!" >nul 2>&1
    goto TSRT_END
)

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
set /p "CTX_KEY=  Context blocks [0, 3, A = 10, B = 10, E = Exit, Enter = B]: "
if not defined CTX_KEY set "CTX_KEY=B"
if defined CTX_KEY set "CTX_KEY=!CTX_KEY: =!"
if /i "!CTX_KEY!"=="0" (set "CTX=0"  & goto CTX_DONE)
if /i "!CTX_KEY!"=="3" (set "CTX=3"  & goto CTX_DONE)
if /i "!CTX_KEY!"=="A" (set "CTX=10" & goto CTX_DONE)
if /i "!CTX_KEY!"=="B" (set "CTX=10" & set "MODEL=translategemma:12b" & goto CTX_DONE)
if /i "!CTX_KEY!"=="E" goto TSRT_END
echo   Invalid choice - please enter 0, 3, A, B or E. Press Enter for B.
goto CTX_INPUT
:CTX_DONE

echo.
echo [FAST-WHISPER] Checking Ollama ...
call :OLLAMA_SETUP
python "%DP%translate_srt.py" --batch "!JOBFILE!" !CTX! "!MODEL!"
if "%errorlevel%"=="-1073741510" goto TSRT_END
if errorlevel 1 echo [FAST-WHISPER] Translation failed - exit code !errorlevel!
if exist "!JOBFILE!" del "!JOBFILE!" >nul 2>&1
goto TSRT_END


:ADD_JOB
set /a job_count+=1
>>"!JOBFILE!" echo "%~1"^|"%~2"^|%~3
exit /b
:: ============================================================
::  Subroutine: check Ollama / Python prerequisites
:: ============================================================
:OLLAMA_SETUP

:: --- Python is required for the Ollama translation ---
where python >nul 2>nul
if errorlevel 1 (
    echo [FAST-WHISPER] Python not found in PATH - required for the Ollama translation.
    echo [FAST-WHISPER] Install Python 3.x and make sure "python" is available.
    goto TSRT_END
)

:: --- Install Ollama if missing ---
where ollama >nul 2>nul
if errorlevel 1 (
    echo [FAST-WHISPER] Ollama not found. Downloading installer ...
    curl -L https://ollama.com/download/OllamaSetup.exe -o "%temp%\OllamaSetup.exe"
    if errorlevel 1 (
        echo [FAST-WHISPER] Ollama download failed - check your internet connection.
        goto TSRT_END
    )
    echo [FAST-WHISPER] Installing Ollama ...
    start /wait "" "%temp%\OllamaSetup.exe" /silent
    if errorlevel 1 echo [FAST-WHISPER] Ollama installer returned an error.
    set "PATH=!PATH!;!LOCALAPPDATA!\Programs\Ollama"
    timeout /t 3 >nul
    where ollama >nul 2>nul
    if errorlevel 1 (
        echo [FAST-WHISPER] Ollama is not available - please install it manually.
        goto TSRT_END
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
        goto TSRT_END
    )
)

exit /b

:TSRT_END
echo.
pause
exit /b
