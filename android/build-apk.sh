#!/usr/bin/env bash
# 无需 Gradle / Android Studio，直接用 Android SDK 的 aapt2+d8+apksigner 手工构建 APK。
# 依赖：JDK 17+（默认 D:/App/java21）、../temp/sdk 下的 platform 与 build-tools。
set -e
cd "$(dirname "$0")"
HERE="$(pwd)"
ROOT="$(cd .. && pwd)"
SDK="$ROOT/temp/sdk"
JAR="$SDK/platform/android-35/android.jar"
BT="$SDK/bt/android-14"
RUNTIME_JDK="${JDK_HOME:-D:/App/java21/bin}"
# d8 8.2 处理 JDK 21 生成的匿名内部类会崩，编译统一用 JDK 8（若存在）
if [ -f "H:/APP/JDK8/bin/javac.exe" ]; then
  JAVAC_JDK="H:/APP/JDK8/bin"
else
  JAVAC_JDK="$RUNTIME_JDK"
fi
PY="$ROOT/.venv/Scripts/python.exe"
OUT="$HERE/out"
APK="$HERE/文件共享中心.apk"

for f in "$JAR" "$BT/aapt2.exe" "$BT/lib/d8.jar" "$BT/lib/apksigner.jar" "$BT/zipalign.exe" "$JAVAC_JDK/javac.exe"; do
  [ -f "$f" ] || { echo "缺少构建工具：$f"; echo "请先运行 tools/setup-sdk.sh 下载 Android SDK 组件"; exit 1; }
done

rm -rf "$OUT"
mkdir -p "$OUT/res" "$OUT/gen" "$OUT/classes" "$OUT/dex"

echo "[1/7] 编译资源"
"$BT/aapt2.exe" compile --dir res -o "$OUT/res/res.zip"

echo "[2/7] 链接 APK 骨架"
"$BT/aapt2.exe" link -o "$OUT/unsigned.apk" -I "$JAR" \
  --manifest AndroidManifest.xml -R "$OUT/res/res.zip" -A assets \
  --java "$OUT/gen" --auto-add-overlay \
  --min-sdk-version 23 --target-sdk-version 35

echo "[3/7] 编译 Java"
SRCS=$(find src out/gen -name "*.java")
"$JAVAC_JDK/javac.exe" -source 8 -target 8 -encoding UTF-8 -nowarn \
  -bootclasspath "$JAR" -cp "$JAR" -d "$OUT/classes" $SRCS
[ -f "$OUT/classes/com/fileshare/phone/MainActivity.class" ] || { echo "Java 编译产物缺失"; exit 1; }

echo "[4/7] 转换为 dex"
(cd "$OUT/classes" && "$JAVAC_JDK/jar.exe" cf "$OUT/classes.jar" .)
"$RUNTIME_JDK/java.exe" -cp "$BT/lib/d8.jar" com.android.tools.r8.D8 \
  --lib "$JAR" --min-api 23 --output "$OUT/dex" "$OUT/classes.jar"

echo "[5/7] 重建 APK 并写入 classes.dex"
"$PY" - "$OUT/unsigned.apk" "$OUT/dex/classes.dex" "$OUT/with-dex.apk" <<'PYCODE'
import sys, zipfile
src, dex, dst = sys.argv[1:4]
zin = zipfile.ZipFile(src, 'r')
zout = zipfile.ZipFile(dst, 'w')
for item in zin.infolist():
    zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
    zi.compress_type = item.compress_type
    zi.external_attr = item.external_attr
    zi.create_system = item.create_system
    zout.writestr(zi, zin.read(item.filename))
zout.write(dex, 'classes.dex', compress_type=zipfile.ZIP_DEFLATED)
zout.close()
zin.close()
PYCODE

echo "[6/7] 对齐"
"$BT/zipalign.exe" -f 4 "$OUT/with-dex.apk" "$OUT/aligned.apk"

echo "[7/7] 签名"
if [ ! -f "$OUT/debug.keystore" ]; then
  "$RUNTIME_JDK/keytool.exe" -genkeypair -keystore "$OUT/debug.keystore" \
    -storepass android -keypass android -alias androiddebugkey \
    -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=FileShare, OU=Dev, O=FileShare, L=CN, ST=CN, C=CN" >/dev/null 2>&1
fi
"$RUNTIME_JDK/java.exe" -cp "$BT/lib/apksigner.jar" com.android.apksigner.ApkSignerTool sign \
  --ks "$OUT/debug.keystore" --ks-pass pass:android --key-pass pass:android \
  --v1-signing-enabled true --v2-signing-enabled true \
  --out "$APK" "$OUT/aligned.apk"
"$RUNTIME_JDK/java.exe" -cp "$BT/lib/apksigner.jar" com.android.apksigner.ApkSignerTool verify "$APK"

echo ""
echo "构建成功：$APK"
ls -l "$APK"
