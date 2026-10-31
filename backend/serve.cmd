@echo off
setlocal
set "ZCODE_HOME=%USERPROFILE%\.zcode"
set "ZCODE_BIN=C:\Program Files\ZCode\resources\glm\zcode.cjs"
set "ZCODE_NODE=C:\Program Files\nodejs\node.exe"
set "ZCODE_ACP_REMOTE=1"
set "ZCODE_ACP_HUB_PORT=8377"
set "ZCODE_ACP_REMOTE_PORT=8378"
set /p ZCODE_ACP_REMOTE_TOKEN=<"%~dp0.token"
if "%~1"=="" (
  set "WORKSPACE=%CD%"
) else (
  set "WORKSPACE=%~1"
)
cd /d "%WORKSPACE%"
node "%~dp0node_modules\zcode-acp-server\dist\cli.js" serve
