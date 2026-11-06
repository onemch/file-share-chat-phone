#!/usr/bin/env bash
# 下载构建 APK 所需的最小 Android SDK 组件（约 120MB），无需 Android Studio / Gradle。
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$ROOT/temp/sdk"
mkdir -p "$SDK"
cd "$SDK"

if [ -x "$ROOT/.venv/Scripts/python.exe" ]; then
  PY="$ROOT/.venv/Scripts/python.exe"
else
  PY="python3"
fi

if [ ! -f platform/android-35/android.jar ]; then
  echo "下载 android-35 平台…"
  curl -sS -L -m 600 -o platform.zip https://dl.google.com/android/repository/platform-35_r02.zip
  "$PY" -m zipfile -e platform.zip platform
fi

if [ ! -f bt/android-14/aapt2.exe ]; then
  echo "下载 build-tools 34…"
  curl -sS -L -m 600 -o build-tools.zip https://dl.google.com/android/repository/build-tools_r34-windows.zip
  "$PY" -m zipfile -e build-tools.zip bt
fi

echo "SDK 就绪：$SDK"
echo " - platform/android-35/android.jar"
echo " - bt/android-14/{aapt2.exe,zipalign.exe,lib/d8.jar,lib/apksigner.jar}"
