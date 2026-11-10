@echo off
chcp 65001 >nul
cd /d "%~dp0"
set "PATH=%USERPROFILE%\.cargo\bin;%PATH%"
where cargo >nul 2>&1
if errorlevel 1 (
  echo 未找到 cargo，请先安装 Rust：https://rustup.rs/
  pause
  exit /b 1
)
echo 编译中（首次会下载依赖，请稍候）...
cargo build --release
if errorlevel 1 (
  echo 编译失败，常见原因是缺少链接器；本目录 README 里有 GNU 工具链的解决办法。
  pause
  exit /b 1
)
copy /Y target\release\file-share-pc.exe file-share-pc.exe >nul
echo.
echo 构建完成：%~dp0file-share-pc.exe
pause
