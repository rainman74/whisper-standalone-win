@echo off
setlocal enabledelayedexpansion

set "DP=%~dp0"

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
::  Ask for context block count
:: ============================================================
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
echo   3    Good compromise                Moderate
echo   4    Stronger context               Slower
echo   5    Very consistent style          Slow
echo   A    Full entity tracking (10)      Slowest
echo.
choice /c 012345AE /n /m "  Context blocks [0-5, A = 10, E = Abort]: "
if errorlevel 8 goto TSRT_END
if errorlevel 7 (set "CTX=10" & goto CTX_DONE)
if errorlevel 6 (set "CTX=5"  & goto CTX_DONE)
if errorlevel 5 (set "CTX=4"  & goto CTX_DONE)
if errorlevel 4 (set "CTX=3"  & goto CTX_DONE)
if errorlevel 3 (set "CTX=2"  & goto CTX_DONE)
if errorlevel 2 (set "CTX=1"  & goto CTX_DONE)
if errorlevel 1 (set "CTX=0"  & goto CTX_DONE)
:CTX_DONE

:: ============================================================
::  Ollama prerequisites
:: ============================================================
echo.
echo  Checking Ollama ...
echo.

call :OLLAMA_SETUP

:: ============================================================
::  Translate loop
:: ============================================================
call :SRT_PROCESS
goto TSRT_END

:SRT_PROCESS
set "i=0"
:SRT_INNER
set /a i+=1
if !i! gtr !file_count! exit /b

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

echo.
echo  Translating: !srt_base!.srt  --^>  !out_base!.DE.srt
echo.

if exist "!out_file!" del "!out_file!" >nul 2>&1
python "%DP%translate_srt.py" "!src!" "!out_file!" !CTX!
if errorlevel 1 (
    echo  [ERROR] Translation failed - exit code !errorlevel!
) else (
    if exist "!out_file!" (
        echo  [OK] German translation created: !out_base!.DE.srt
    ) else (
        echo  [ERROR] Translation failed - no output written.
    )
)
goto SRT_INNER

:: ============================================================
::  Subroutine: check Ollama / Python prerequisites
:: ============================================================
:OLLAMA_SETUP

:: --- Python is required for the Ollama translation ---
where python >nul 2>nul
if errorlevel 1 (
    echo  [ERROR] Python not found in PATH - required for the Ollama translation.
    echo          Install Python 3.x and make sure "python" is available.
    goto TSRT_END
)

:: --- Install Ollama if missing ---
where ollama >nul 2>nul
if errorlevel 1 (
    echo  Ollama not found. Downloading installer ...
    curl -L https://ollama.com/download/OllamaSetup.exe -o "%temp%\OllamaSetup.exe"
    if errorlevel 1 (
        echo  [ERROR] Ollama download failed - check your internet connection.
        goto TSRT_END
    )
    echo  Installing Ollama ...
    start /wait "" "%temp%\OllamaSetup.exe" /silent
    if errorlevel 1 echo  [WARNING] Ollama installer returned an error.
    set "PATH=!PATH!;!LOCALAPPDATA!\Programs\Ollama"
    timeout /t 3 >nul
    where ollama >nul 2>nul
    if errorlevel 1 (
        echo  [ERROR] Ollama is not available - please install it manually.
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
    echo  Installing Python package "requests" ...
    python -m pip install requests
    if errorlevel 1 (
        echo  [ERROR] Could not install "requests" - translation will not work.
        goto TSRT_END
    )
)

exit /b

:TSRT_END
echo.
pause
exit /b
