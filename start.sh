#!/usr/bin/env bash
# Linux / macOS / 任意带 Python 的设备
set -e
cd "$(dirname "$0")"

if [ -x .venv/bin/python ]; then
  PY=.venv/bin/python
else
  PY=python3
  if ! "$PY" -c "import flask, flask_cors, flask_sock" 2>/dev/null; then
    echo "首次运行：创建虚拟环境并安装依赖…"
    "$PY" -m venv .venv 2>/dev/null && PY=.venv/bin/python || true
    "$PY" -m pip install -q -r requirements.txt
  fi
fi

exec "$PY" server.py "$@"
