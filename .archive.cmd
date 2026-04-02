@echo off

tar -a -c -f whisper-standalone-win.zip --exclude="_models" --exclude=".git" --exclude=".gitattributes" --exclude=".gitignore" --exclude=".archive.cmd" --exclude="whisper-standalone-win.zip" --exclude="whisper-nvidia-dll.zip" --exclude="cu*.dll" --exclude="nv*.dll" *

tar -a -c -f whisper-nvidia-dll.zip _xxl_data\torch\lib\cu*.dll _xxl_data\torch\lib\nv*.dll
