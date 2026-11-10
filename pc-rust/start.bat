@echo off
chcp 65001 >nul
cd /d "%~dp0"
if not exist "file-share-pc.exe" (
  echo 尚未编译。请先双击 build.bat 生成 file-share-pc.exe。
  pause
  exit /b 1
)
file-share-pc.exe %*
echo.
echo 服务已停止。
pause
