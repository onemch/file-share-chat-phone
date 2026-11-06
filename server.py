#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
文件共享中心 · 手机版服务端

角色：任意一台设备（PC / 安卓 Termux / 云服务器）运行本文件即成为「主机」，
      持有共享文件夹；其他手机用浏览器或 PWA 打开 http://主机IP:端口 加入。

启动：python server.py --port 5000
依赖：pip install -r requirements.txt
"""
import argparse
import json
import os
import re
import shutil
import socket
import sys
import threading
import time
import zipfile
from collections import deque
from datetime import datetime

from flask import Flask, abort, jsonify, request, send_from_directory
from flask_cors import CORS
from flask_sock import Sock

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

APP_DIR = os.path.dirname(os.path.abspath(__file__))
STATIC_DIR = os.path.join(APP_DIR, 'static')
TEMP_DIR = os.path.join(APP_DIR, 'temp')

app = Flask(__name__, static_folder=None)
app.config['MAX_CONTENT_LENGTH'] = None
CORS(app, resources={r'/*': {'origins': '*'}})
sock = Sock(app)

# ---------------------------------------------------------------- 配置（由命令行覆盖）
SHARE_DIR = os.path.join(APP_DIR, 'download')
PORT = 5000
HOST = '0.0.0.0'

clients = {}                 # user_id -> websocket
client_meta = {}             # user_id -> {'nick': ...}
clients_lock = threading.Lock()
chat_history = deque(maxlen=100)
history_lock = threading.Lock()

ROOT_ASSETS = {
    'manifest.webmanifest', 'sw.js', 'icon-192.png',
    'icon-512.png', 'apple-touch-icon.png', 'favicon.ico',
}


# ---------------------------------------------------------------- 工具
def human_size(size):
    if size < 1024:
        return f'{size} B'
    if size < 1024 ** 2:
        return f'{size / 1024:.2f} KB'
    if size < 1024 ** 3:
        return f'{size / 1024 ** 2:.2f} MB'
    return f'{size / 1024 ** 3:.2f} GB'


def safe_basename(raw):
    """顶层项目名：只保留单个文件名，剔除路径分隔符与非法字符。"""
    if not isinstance(raw, str):
        return None
    name = raw.replace('\\', '/').split('/')[-1].strip()
    if not name or name in ('.', '..'):
        return None
    name = re.sub(r'[<>:"|?*\x00-\x1f]', '_', name).strip('. ')
    if not name or len(name) > 200:
        return None
    return name


def resolve_within(raw):
    """把用户给的名称解析为 SHARE_DIR 内的绝对路径，越界返回 None。"""
    if not isinstance(raw, str) or not raw.strip():
        return None
    rel = raw.replace('\\', '/').strip()
    if rel.startswith('/') or os.path.isabs(rel) or re.match(r'^[A-Za-z]:', rel):
        return None
    parts = [p for p in rel.split('/') if p not in ('', '.')]
    if not parts or any(p == '..' for p in parts):
        return None
    base = os.path.abspath(SHARE_DIR)
    target = os.path.abspath(os.path.join(base, *parts))
    if target == base or not target.startswith(base + os.sep):
        return None
    return target


def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return '127.0.0.1'


def item_info(path):
    stat = os.stat(path)
    info = {
        'name': os.path.basename(path),
        'size': human_size(stat.st_size),
        'bytes': stat.st_size,
        'modified': stat.st_mtime,
        'modified_str': datetime.fromtimestamp(stat.st_mtime).strftime('%Y-%m-%d %H:%M'),
    }
    if os.path.isdir(path):
        total, count = 0, 0
        for root, _dirs, files in os.walk(path):
            for f in files:
                try:
                    total += os.path.getsize(os.path.join(root, f))
                    count += 1
                except OSError:
                    pass
        info.update(type='folder', size=human_size(total), bytes=total, file_count=count)
    else:
        info['type'] = 'file'
    return info


def broadcast(message, sender_id=None):
    payload = json.dumps(message, ensure_ascii=False)
    with clients_lock:
        targets = [(cid, ws) for cid, ws in clients.items() if cid != sender_id]
    dead = []
    for cid, ws in targets:
        try:
            ws.send(payload)
        except Exception:
            dead.append(cid)
    if dead:
        with clients_lock:
            for cid in dead:
                clients.pop(cid, None)
                client_meta.pop(cid, None)


def clean_nick(raw):
    """兼容个别客户端未对查询串做 UTF-8 编码的情况。"""
    s = (raw or '').strip()[:20]
    if any(0x80 <= ord(c) <= 0xFF for c in s):
        try:
            s = s.encode('latin-1').decode('utf-8')
        except (UnicodeEncodeError, UnicodeDecodeError):
            pass
    return re.sub(r'[\x00-\x1f]', '', s).strip()[:20]


def online_users():
    with clients_lock:
        return [client_meta.get(cid, {}).get('nick', cid) for cid in clients]


def push_history(message):
    with history_lock:
        chat_history.append(message)


def make_zip(names, prefix='files'):
    os.makedirs(TEMP_DIR, exist_ok=True)
    for old in os.listdir(TEMP_DIR):
        if old.startswith(prefix + '_') and old.endswith('.zip'):
            try:
                if time.time() - os.path.getmtime(os.path.join(TEMP_DIR, old)) > 3600:
                    os.remove(os.path.join(TEMP_DIR, old))
            except OSError:
                pass

    zip_name = f"{prefix}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.zip"
    zip_path = os.path.join(TEMP_DIR, zip_name)
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
        for name in names:
            path = resolve_within(name)
            if not path or not os.path.exists(path):
                continue
            if os.path.isdir(path):
                for root, _dirs, files in os.walk(path):
                    for filename in files:
                        fp = os.path.join(root, filename)
                        arc = os.path.join(name, os.path.relpath(fp, path))
                        try:
                            zf.write(fp, arc)
                        except (FileNotFoundError, PermissionError):
                            pass
            else:
                try:
                    zf.write(path, name)
                except (FileNotFoundError, PermissionError):
                    pass

    def cleanup():
        time.sleep(300)
        for _ in range(10):
            try:
                if os.path.exists(zip_path):
                    os.remove(zip_path)
                return
            except OSError:
                time.sleep(5)

    threading.Thread(target=cleanup, daemon=True).start()
    return TEMP_DIR, zip_name


def parse_names():
    if request.method == 'POST':
        payload = request.get_json(silent=True) or {}
        names = payload.get('names') or []
        if isinstance(names, str):
            names = [names]
    else:
        names = request.args.getlist('name') or [
            n for n in request.args.get('names', '').replace('\r', '\n').split('\n') if n
        ]
    result, seen = [], set()
    for n in names:
        if not isinstance(n, str):
            continue
        name = safe_basename(n)
        if not name or name in seen or not resolve_within(name):
            continue
        seen.add(name)
        result.append(name)
    return result


# ---------------------------------------------------------------- 静态资源
@app.route('/')
def index():
    resp = send_from_directory(STATIC_DIR, 'index.html')
    resp.headers['Cache-Control'] = 'no-cache'
    return resp


@app.route('/static/<path:filename>')
def static_files(filename):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+', filename) or filename.startswith('.'):
        abort(404)
    return send_from_directory(STATIC_DIR, filename)


@app.route('/manifest.webmanifest')
@app.route('/sw.js')
@app.route('/icon-192.png')
@app.route('/icon-512.png')
@app.route('/apple-touch-icon.png')
@app.route('/favicon.ico')
def root_assets():
    name = request.path.lstrip('/')
    if name not in ROOT_ASSETS:
        abort(404)
    if name == 'favicon.ico':
        name = 'icon-192.png'
    resp = send_from_directory(STATIC_DIR, name)
    if request.path.endswith('sw.js'):
        resp.headers['Service-Worker-Allowed'] = '/'
    resp.headers['Cache-Control'] = 'no-cache'
    return resp


@app.route('/qr.png')
def qr_png():
    """生成「加入本主机」二维码，其他手机扫码即自动连上。"""
    try:
        import io
        import qrcode
        from flask import Response
        ip = get_local_ip()
        url = f'http://{ip}:{PORT}/?host=http%3A%2F%2F{ip}%3A{PORT}'
        img = qrcode.make(url, box_size=8, border=2)
        buf = io.BytesIO()
        img.save(buf, format='PNG')
        return Response(buf.getvalue(), mimetype='image/png',
                        headers={'Cache-Control': 'no-store'})
    except ImportError:
        abort(404)
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


# ---------------------------------------------------------------- API
@app.after_request
def notify_files_changed(resp):
    """任一设备改动共享目录后，通知所有在线客户端立即刷新列表。"""
    if resp.status_code < 400 and request.method in ('POST', 'DELETE') and \
            request.path.startswith(('/upload', '/delete', '/clear-download')):
        broadcast({'type': 'files_changed'})
    return resp


@app.route('/health')
def health():
    try:
        count = len(os.listdir(SHARE_DIR))
    except OSError:
        count = 0
    return jsonify({
        'ok': True, 'app': '文件共享中心 · 手机版', 'version': '1.0',
        'time': datetime.now().isoformat(timespec='seconds'),
        'lan_ip': get_local_ip(), 'port': PORT,
        'online': len(clients), 'items': count,
    })


@app.route('/files')
def list_files():
    items = []
    try:
        for name in os.listdir(SHARE_DIR):
            path = os.path.join(SHARE_DIR, name)
            try:
                items.append(item_info(path))
            except OSError:
                continue
    except OSError:
        pass
    items.sort(key=lambda x: (x['type'] == 'file', -x['modified']))
    return jsonify(items)


@app.route('/upload', methods=['POST'])
def upload_file():
    files = request.files.getlist('file') or request.files.getlist('files[]')
    files = [f for f in files if f and f.filename]
    if not files:
        return jsonify({'success': False, 'message': '没有选择文件'}), 400

    saved, failed = [], []
    for f in files:
        name = safe_basename(f.filename)
        if not name:
            failed.append(f.filename)
            continue
        path = os.path.join(SHARE_DIR, name)
        stem, ext = os.path.splitext(name)
        counter = 1
        while os.path.exists(path):
            name = f'{stem}({counter}){ext}'
            path = os.path.join(SHARE_DIR, name)
            counter += 1
        try:
            f.save(path)
            saved.append(name)
        except Exception as e:
            failed.append(f'{name}: {e}')

    if not saved:
        return jsonify({'success': False, 'message': '上传失败', 'failed': failed}), 500
    return jsonify({'success': True, 'message': f'上传成功 {len(saved)} 个文件',
                    'filenames': saved, 'failed': failed})


@app.route('/upload-folder', methods=['POST'])
def upload_folder():
    files = request.files.getlist('files[]') or request.files.getlist('folder[]')
    files = [f for f in files if f and f.filename]
    if not files:
        return jsonify({'success': False, 'message': '文件夹为空'}), 400

    folder_name = safe_basename(request.form.get('folder_name', '')) or '上传文件夹'
    folder_path = os.path.join(SHARE_DIR, folder_name)
    counter = 1
    while os.path.exists(folder_path):
        folder_path = os.path.join(SHARE_DIR, f'{folder_name}({counter})')
        counter += 1
    os.makedirs(folder_path)

    count = 0
    for f in files:
        rel = f.filename.replace('\\', '/').lstrip('/')
        parts = [p for p in rel.split('/') if p not in ('', '.')]
        if not parts or any(p == '..' for p in parts) or any(
                re.search(r'[<>:"|?*\x00-\x1f]', p) for p in parts):
            continue
        dest = os.path.abspath(os.path.join(folder_path, *parts))
        if not dest.startswith(os.path.abspath(folder_path) + os.sep):
            continue
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        try:
            f.save(dest)
            count += 1
        except OSError:
            pass

    return jsonify({'success': True, 'message': f'文件夹上传成功，共 {count} 个文件',
                    'folder_name': os.path.basename(folder_path)})


@app.route('/download/<path:filename>')
def download_one(filename):
    path = resolve_within(filename)
    if not path or not os.path.exists(path):
        return jsonify({'success': False, 'message': '文件不存在'}), 404
    if os.path.isdir(path):
        folder, zip_name = make_zip([filename], prefix='folder')
        return send_from_directory(folder, zip_name, as_attachment=True,
                                   download_name=os.path.basename(path) + '.zip')
    return send_from_directory(SHARE_DIR, filename, as_attachment=True)


@app.route('/preview/<path:filename>')
def preview_file(filename):
    """在线预览（不强制下载），供手机端查看图片/视频/PDF。"""
    path = resolve_within(filename)
    if not path or not os.path.isfile(path):
        return jsonify({'success': False, 'message': '文件不存在'}), 404
    resp = send_from_directory(SHARE_DIR, filename, as_attachment=False)
    resp.headers['Cache-Control'] = 'no-store'
    return resp


@app.route('/download-selected')
def download_selected():
    names = parse_names()
    if not names:
        return jsonify({'success': False, 'message': '未选择任何项目'}), 400
    existing = [n for n in names if os.path.exists(os.path.join(SHARE_DIR, n))]
    if not existing:
        return jsonify({'success': False, 'message': '选中的项目不存在'}), 404
    folder, zip_name = make_zip(existing, prefix='selected')
    return send_from_directory(folder, zip_name, as_attachment=True)


@app.route('/download-all')
def download_all():
    try:
        names = [n for n in os.listdir(SHARE_DIR) if resolve_within(n)]
    except OSError:
        names = []
    if not names:
        return jsonify({'success': False, 'message': '暂无可下载的文件'}), 404
    folder, zip_name = make_zip(names, prefix='files')
    return send_from_directory(folder, zip_name, as_attachment=True)


@app.route('/delete-selected', methods=['POST'])
def delete_selected():
    names = parse_names()
    if not names:
        return jsonify({'success': False, 'message': '未选择任何项目'}), 400
    deleted, failed = 0, []
    for name in names:
        path = resolve_within(name)
        if not path or not os.path.exists(path):
            failed.append(name)
            continue
        try:
            if os.path.isdir(path):
                shutil.rmtree(path)
            else:
                os.remove(path)
            deleted += 1
        except OSError:
            failed.append(name)
    return jsonify({'success': deleted > 0, 'deleted': deleted, 'failed': failed,
                    'message': f'成功删除 {deleted} 个项目' if deleted else '删除失败'})


@app.route('/delete/<path:filename>', methods=['DELETE'])
def delete_one(filename):
    path = resolve_within(filename)
    if not path or not os.path.exists(path):
        return jsonify({'success': False, 'message': '文件不存在'}), 404
    try:
        if os.path.isdir(path):
            shutil.rmtree(path)
        else:
            os.remove(path)
        return jsonify({'success': True, 'message': '删除成功'})
    except OSError as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@app.route('/clear-download', methods=['POST'])
def clear_all():
    deleted = 0
    for name in os.listdir(SHARE_DIR):
        path = os.path.join(SHARE_DIR, name)
        if not resolve_within(name):
            continue
        try:
            if os.path.isdir(path):
                shutil.rmtree(path, ignore_errors=True)
            else:
                os.remove(path)
            deleted += 1
        except OSError:
            pass
    return jsonify({'success': True, 'message': f'已清空 {deleted} 个项目'})


# ---------------------------------------------------------------- 群聊 WebSocket
@sock.route('/chat')
def chat(ws):
    user_id = f"{request.remote_addr}:{request.environ.get('REMOTE_PORT', '0')}"
    nick = clean_nick(request.args.get('nick')) or user_id.split(':')[0]

    with clients_lock:
        clients[user_id] = ws
        client_meta[user_id] = {'nick': nick}

    ws.send(json.dumps({
        'type': 'welcome', 'user_id': user_id, 'nick': nick,
        'online_count': len(clients), 'users': online_users(),
    }, ensure_ascii=False))

    # 只回放聊天与分享通知，不回放历史加入/离开提示
    with history_lock:
        history = [m for m in chat_history if m.get('type') in ('chat', 'file_shared')]
    for msg in history:
        try:
            ws.send(json.dumps(msg, ensure_ascii=False))
        except Exception:
            break

    sys_msg = {'type': 'system', 'message': f'{nick} 加入了共享',
               'timestamp': datetime.now().isoformat(timespec='seconds'),
               'online_count': len(clients), 'users': online_users()}
    push_history(sys_msg)
    broadcast(sys_msg, sender_id=user_id)

    try:
        while True:
            data = ws.receive()
            if data is None:
                break
            try:
                payload = json.loads(data)
            except (TypeError, ValueError):
                continue
            kind = payload.get('type')
            if kind not in ('chat', 'file_shared'):
                continue
            text = str(payload.get('message', '')).strip()[:2000]
            if not text:
                continue
            msg = {
                'type': kind, 'user_id': user_id, 'nick': nick, 'message': text,
                'timestamp': datetime.now().isoformat(timespec='seconds'),
            }
            if kind == 'chat':
                push_history(msg)
            broadcast(msg, sender_id=user_id)
    except Exception as e:
        print(f'[chat] {user_id}: {e}')
    finally:
        with clients_lock:
            clients.pop(user_id, None)
            client_meta.pop(user_id, None)
            left_count = len(clients)
        leave = {'type': 'system', 'message': f'{nick} 离开了共享',
                 'timestamp': datetime.now().isoformat(timespec='seconds'),
                 'online_count': left_count, 'users': online_users()}
        push_history(leave)
        broadcast(leave)


# ---------------------------------------------------------------- 启动
def main():
    global SHARE_DIR, PORT, HOST
    parser = argparse.ArgumentParser(description='文件共享中心 · 手机版服务端')
    parser.add_argument('--host', default='0.0.0.0', help='监听地址，默认 0.0.0.0')
    parser.add_argument('--port', type=int, default=5000, help='端口，默认 5000')
    parser.add_argument('--dir', default=None, help='共享目录，默认项目下 download/')
    parser.add_argument('--no-qr', action='store_true', help='不生成访问二维码图片')
    args = parser.parse_args()

    HOST, PORT = args.host, args.port
    SHARE_DIR = os.path.abspath(args.dir) if args.dir else os.path.join(APP_DIR, 'download')
    os.makedirs(SHARE_DIR, exist_ok=True)
    os.makedirs(TEMP_DIR, exist_ok=True)

    lan = get_local_ip()
    url = f'http://{lan}:{PORT}'
    print('=' * 56)
    print('  文件共享中心 · 手机版   [主机已启动]')
    print('=' * 56)
    print(f'  本机访问     http://127.0.0.1:{PORT}')
    print(f'  局域网访问   {url}')
    print(f'  共享目录     {SHARE_DIR}')
    print('  其他手机：与主机连同一 WiFi，浏览器打开上面的「局域网访问」地址')
    print('  提示：安卓/iPhone 浏览器菜单里选「添加到主屏幕」即可当 App 用')
    print('=' * 56)

    if not args.no_qr:
        try:
            import qrcode
            img = qrcode.make(f'{url}/?host=' + url.replace(':', '%3A').replace('/', '%2F'),
                              box_size=8, border=2)
            qr_path = os.path.join(APP_DIR, '访问二维码.png')
            img.save(qr_path)
            print(f'  扫码加入     已生成 {qr_path}')
        except ImportError:
            print('  扫码加入     未安装 qrcode，跳过（pip install qrcode 可启用）')
        except Exception as e:
            print(f'  扫码加入     生成失败：{e}')

    try:
        app.run(host=HOST, port=PORT, threaded=True, debug=False, use_reloader=False)
    except OSError as e:
        print(f'\n[启动失败] 端口 {PORT} 可能被占用：{e}')
        print('换个端口试试：python server.py --port 5001')
        sys.exit(1)


if __name__ == '__main__':
    main()
