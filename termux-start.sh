#!/data/data/com.termux/files/usr/bin/bash
# 安卓 Termux 当主机：把整个项目目录放到 Termux 可访问的位置后运行
#   cd ~/file-share-chat-phone && bash termux-start.sh
cd "$(dirname "$0")" || exit 1

echo "== 文件共享中心 · 手机版（Termux 主机）=="
echo "1/3 检查 Python…"
pkg install -y python >/dev/null 2>&1 || true

echo "2/3 检查依赖…"
python -c "import flask, flask_cors, flask_sock" 2>/dev/null || \
  pip install -q flask flask-cors flask-sock
# 二维码是可选增强，装不上不影响文件共享与群聊
python -c "import qrcode, PIL" 2>/dev/null || \
  (pip install -q qrcode pillow 2>/dev/null || echo "   （二维码不可用，跳过）")

echo "3/3 防止休眠…"
termux-wake-lock 2>/dev/null || true
echo ""
echo "保持 Termux 在前台运行，其他手机连同一 WiFi 即可访问。"
echo "按 Ctrl+C 停止服务。"
echo ""
python server.py --port 5000 "$@"
