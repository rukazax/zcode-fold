@echo off
setlocal
set "ZCODE_ACP_REMOTE=1"
set "ZCODE_ACP_HUB_PORT=8377"
set "ZCODE_ACP_REMOTE_PORT=8378"
set "ZCODE_NODE=C:\Program Files\nodejs\node.exe"
set /p ZCODE_ACP_REMOTE_TOKEN=<"%~dp0.token"
cd /d "%~dp0"
node node_modules\zcode-acp-server\dist\cli.js hub
