@echo off & setlocal enabledelayedexpansion

:INIT
set ZIP_BASE=whisper-standalone-win.zip
set ZIP_NV=whisper-nvidia-dll.zip

:MAIN
echo Erstelle Basispaket (ohne NVIDIA DLLs)...
tar -a -c -f %ZIP_BASE% --exclude="_models" --exclude=".git" --exclude=".gitattributes" --exclude=".gitignore" --exclude=".archive.cmd" --exclude="%ZIP_BASE%" --exclude="%ZIP_NV%" --exclude="cu*.dll" --exclude="nv*.dll" *

echo Erstelle NVIDIA Paket (nur DLLs)...
tar -a -c -f %ZIP_NV% _xxl_data\torch\lib\cu*.dll _xxl_data\torch\lib\nv*.dll

echo Fertig!

:END
