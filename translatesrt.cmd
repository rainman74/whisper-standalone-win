@echo off
color 0A
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
echo   3    Good compromise                Moderate     ^<-- Default
echo   5    Very consistent style          Slow
echo.
choice /c 012345E /n /m "  Context blocks [0-5, E = Abort]: "
if errorlevel 7 goto TSRT_END
if errorlevel 6 (set "CTX=5" & goto CTX_DONE)
if errorlevel 5 (set "CTX=4" & goto CTX_DONE)
if errorlevel 4 (set "CTX=3" & goto CTX_DONE)
if errorlevel 3 (set "CTX=2" & goto CTX_DONE)
if errorlevel 2 (set "CTX=1" & goto CTX_DONE)
if errorlevel 1 (set "CTX=0" & goto CTX_DONE)
:CTX_DONE

:: ============================================================
::  Ollama prerequisites
:: ============================================================
echo.
echo  Checking Ollama ...
echo.

where ollama >nul 2>nul
if errorlevel 1 (
    echo  Ollama not found. Downloading installer ...
    curl -L https://ollama.com/download/OllamaSetup.exe -o "%temp%\OllamaSetup.exe"
    echo  Installing Ollama ...
    start /wait "" "%temp%\OllamaSetup.exe" /silent
    set "PATH=%PATH%;%LocalAppData%\Programs\Ollama"
    timeout /t 3 >nul
)

set "OLLAMA_HOST=127.0.0.1"
set "OLLAMA_FLASH_ATTENTION=1"
set "OLLAMA_KV_CACHE_TYPE=q4_0"
set "OLLAMA_GPU_OVERHEAD=0"
set "OLLAMA_NUM_PARALLEL=1"
set "OLLAMA_LOG_LEVEL=error"
set "OLLAMA_NUM_THREADS=8"

python -c "import requests" >nul 2>nul
if errorlevel 1 pip install requests

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

python "%DP%translate_srt.py" "!src!" "!out_file!" !CTX!

if exist "!out_file!" echo  German translation created successfully.
if not exist "!out_file!" echo  [ERROR] Translation failed.

goto SRT_INNER

:TSRT_END
echo.
color 0A
pause
color
exit /b
