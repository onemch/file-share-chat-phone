@echo off
chcp 65001 >nul
cd /d "%~dp0"
where bash >nul 2>&1
if errorlevel 1 (
  echo 未找到 Git Bash。请安装 Git for Windows，或在 Git Bash 中执行：bash build-apk.sh
  pause
  exit /b 1
)
bash build-apk.sh
echo.
pause
