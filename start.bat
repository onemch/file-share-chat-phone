@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "PY=.venv\Scripts\python.exe"

if not exist "%PY%" (
  echo [首次运行] 正在创建虚拟环境...
  python -m venv .venv
  if errorlevel 1 goto :failed
  "%PY%" -m pip install --disable-pip-version-check -i https://pypi.org/simple -r requirements.txt
  if errorlevel 1 goto :failed
)

"%PY%" -c "import flask, flask_cors, flask_sock" >nul 2>&1
if errorlevel 1 (
  echo 正在补齐依赖...
  "%PY%" -m pip install --disable-pip-version-check -i https://pypi.org/simple -r requirements.txt
  if errorlevel 1 goto :failed
)

echo.
"%PY%" server.py %*
echo.
echo 服务已停止。
pause
exit /b 0

:failed
echo.
echo 依赖安装失败。请检查网络，或手动执行：
echo   pip install -r requirements.txt
pause
exit /b 1
