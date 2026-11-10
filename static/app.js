(function () {
  'use strict';

  const $ = (id) => document.getElementById(id);
  const LS = { base: 'fsc.base', nick: 'fsc.nick', hosts: 'fsc.hosts' };
  const IMAGE_EXT = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'svg'];
  const VIDEO_EXT = ['mp4', 'mov', 'm4v', 'webm'];
  const AUDIO_EXT = ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg'];
  const ICON_DOWNLOAD = '<svg viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m0 0 4-4m-4 4-4-4"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/></svg>';
  const ICON_TRASH = '<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 7h16M9 7V4h6v3m-8 0 1 13h8l1-13M10 11v6m4-6v6"/></svg>';

  const state = {
    base: location.origin,
    nick: '',
    files: [],
    selected: new Set(),
    manage: false,
    query: '',
    tab: 'files',
    myId: '',
    online: 0,
    unread: 0,
    ws: null,
    wsRetry: 0,
    wsTimer: null,
    confirmCb: null,
    installPrompt: null,
    lanUrl: null,
    lanIp: null,
    scanStream: null,
    scanRaf: 0,
    discoverRunning: false,
    discoverScanned: 0,
    discoverWatchdog: null,
    hostInputTimer: null,
    lastClip: '',
  };

  // ---------------------------------------------------------------- 基础工具
  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
    }[c]));
  }

  let toastTimer;
  function toast(msg) {
    const el = $('toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 2400);
  }

  function normalizeBase(raw) {
    let v = String(raw || '').trim().replace(/\/+$/, '');
    if (!v) return null;
    if (!/^https?:\/\//i.test(v)) v = 'http://' + v;
    try {
      const u = new URL(v);
      if (!u.hostname) return null;
      return u.origin;
    } catch (e) { return null; }
  }

  function shortHost(base) {
    try { return new URL(base).host; } catch (e) { return base; }
  }

  function api(path, opts) {
    opts = opts || {};
    opts.cache = 'no-store';
    return fetch(state.base + path, opts).then((r) => {
      if (!r.ok) throw new Error('HTTP ' + r.status);
      return r.json();
    });
  }

  function fileUrl(name, preview) {
    return state.base + (preview ? '/preview/' : '/download/') + encodeURIComponent(name);
  }

  function triggerDownload(url, name) {
    const a = document.createElement('a');
    a.href = url;
    a.download = name || '';
    a.rel = 'noopener';
    if (new URL(url).origin !== location.origin) a.target = '_blank';
    document.body.appendChild(a);
    a.click();
    a.remove();
  }

  function extOf(name) {
    const i = String(name).lastIndexOf('.');
    return i < 0 ? '' : name.slice(i + 1).toLowerCase();
  }

  function iconFor(item) {
    if (item.type === 'folder') return { emoji: '📁', cls: 'i-folder' };
    const e = extOf(item.name);
    if (IMAGE_EXT.includes(e)) return { emoji: '🖼️', cls: 'i-image' };
    if (VIDEO_EXT.includes(e)) return { emoji: '🎬', cls: 'i-video' };
    if (AUDIO_EXT.includes(e)) return { emoji: '🎵', cls: 'i-audio' };
    if (['zip', 'rar', '7z', 'tar', 'gz'].includes(e)) return { emoji: '🗜️', cls: 'i-archive' };
    if (['apk', 'exe', 'msi', 'dmg', 'ipa'].includes(e)) return { emoji: '📦', cls: 'i-archive' };
    if (['pdf', 'doc', 'docx', 'txt', 'md', 'xls', 'xlsx', 'ppt', 'pptx'].includes(e)) return { emoji: '📄', cls: 'i-doc' };
    return { emoji: '📃', cls: '' };
  }

  // ---------------------------------------------------------------- 主机配置
  function readStore(key, fallback) {
    try { return localStorage.getItem(key) || fallback; } catch (e) { return fallback; }
  }
  function writeStore(key, value) {
    try { localStorage.setItem(key, value); } catch (e) { /* 隐私模式忽略 */ }
  }
  function savedHosts() {
    try { return JSON.parse(readStore(LS.hosts, '[]')) || []; } catch (e) { return []; }
  }
  function rememberHost(base) {
    const list = [base].concat(savedHosts().filter((h) => h !== base)).slice(0, 5);
    writeStore(LS.hosts, JSON.stringify(list));
  }

  function setStatus(ok, text) {
    $('status-dot').parentElement.classList.toggle('status-ok', !!ok);
    $('status-dot').parentElement.classList.toggle('status-bad', ok === false);
    $('status-text').textContent = text;
    $('state-tag').textContent = ok ? '已连接' : '不可达';
  }

  function applyBase(base, quiet) {
    state.base = base;
    state.lanUrl = null;
    writeStore(LS.base, base);
    rememberHost(base);
    state.selected.clear();
    state.files = [];
    $('host-caption').textContent = shortHost(base) + ' · 共享空间';
    $('current-host').textContent = base;
    $('host-input').value = base;
    renderInvite();
    renderSavedHosts();
    if (!quiet) toast('已切换到 ' + shortHost(base));
    checkHealth();
    loadFiles();
    connectWS();
  }

  function connectHost(raw) {
    const base = normalizeBase(raw);
    if (!base) { toast('地址格式不对，例如 http://192.168.1.5:5000'); return; }
    applyBase(base);
  }

  function checkHealth() {
    return api('/health').then((d) => {
      setStatus(true, '已连接');
      $('stat-online').textContent = d.online != null ? d.online : '—';
      $('stat-files').textContent = d.items != null ? d.items : '—';
      $('stat-lan').textContent = d.lan_ip || '—';
      // 分享给别人的链接必须用局域网 IP，不能用 127.0.0.1（App 内嵌服务尤其重要）
      state.lanIp = d.lan_ip || null;
      state.lanUrl = (d.lan_ip && d.port) ? ('http://' + d.lan_ip + ':' + d.port) : null;
      state.online = d.online || 0;
      $('online-count').textContent = state.online;
      renderInvite();
      return true;
    }).catch(() => {
      setStatus(false, '主机不可达');
      $('stat-online').textContent = '—';
      $('stat-files').textContent = '—';
      $('stat-lan').textContent = '—';
      renderInvite();
      return false;
    });
  }

  function renderSavedHosts() {
    const box = $('saved-hosts');
    box.textContent = '';
    const list = savedHosts().filter((h) => h !== state.base);
    if (!list.length) return;
    const label = document.createElement('div');
    label.className = 'tip';
    label.textContent = '最近连接过的主机';
    box.appendChild(label);
    list.forEach((h) => {
      const row = document.createElement('div');
      row.className = 'saved-host';
      const span = document.createElement('span');
      span.textContent = shortHost(h);
      const use = document.createElement('button');
      use.type = 'button';
      use.textContent = '连接';
      use.addEventListener('click', () => applyBase(h));
      const del = document.createElement('button');
      del.type = 'button';
      del.textContent = '×';
      del.setAttribute('aria-label', '移除');
      del.addEventListener('click', () => {
        writeStore(LS.hosts, JSON.stringify(savedHosts().filter((x) => x !== h)));
        renderSavedHosts();
      });
      row.append(span, use, del);
      box.appendChild(row);
    });
  }

  // ---------------------------------------------------------------- 连接增强
  function shareUrl() {
    const target = state.lanUrl || state.base;
    return target + '/?host=' + encodeURIComponent(target);
  }

  /** 前端生成邀请二维码，不依赖服务端 /qr.png，App 内嵌服务也能显示。 */
  function renderInvite() {
    const url = shareUrl();
    const canvas = $('qr-canvas');
    $('qr-url').textContent = '主机地址 ' + (state.lanUrl || state.base);
    $('btn-share-link').hidden = !navigator.share;
    if (!canvas || typeof window.qrcode !== 'function') {
      $('qr-url').textContent = url;
      return;
    }
    try {
      const qr = window.qrcode(0, 'M');
      qr.addData(url);
      qr.make();
      const count = qr.getModuleCount();
      const quiet = 2;
      const total = count + quiet * 2;
      const size = canvas.width;
      const cell = Math.max(1, Math.floor(size / total));
      const offset = Math.floor((size - cell * total) / 2);
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = '#fff';
      ctx.fillRect(0, 0, size, size);
      ctx.fillStyle = '#1F2233';
      for (let r = 0; r < count; r++) {
        for (let c = 0; c < count; c++) {
          if (qr.isDark(r, c)) {
            ctx.fillRect(offset + (c + quiet) * cell, offset + (r + quiet) * cell, cell, cell);
          }
        }
      }
    } catch (e) {
      $('qr-url').textContent = url;
    }
  }

  /** 从任意文本里提取主机地址：分享链接 / URL / 纯 IP / IP:端口。 */
  function parseHostText(text) {
    if (!text) return null;
    const s = String(text).trim();
    const m = s.match(/https?:\/\/[^\s"'<>\u4e00-\u9fa5]+/i);
    if (m) {
      try {
        const u = new URL(m[0]);
        const q = u.searchParams.get('host');
        const base = normalizeBase(q || u.origin);
        if (base) return base;
      } catch (e) { /* 继续尝试纯 IP */ }
    }
    const p = s.match(/\b(\d{1,3}(?:\.\d{1,3}){3})(?::(\d{2,5}))?\b/);
    if (p) return normalizeBase('http://' + p[1] + ':' + (p[2] || '5000'));
    return null;
  }

  function autoConnectFromText(text, source) {
    const base = parseHostText(text);
    if (!base) { toast('没识别到主机地址，请检查内容'); return false; }
    if (base === state.base) { toast('已经在连接这台主机了'); return true; }
    applyBase(base);
    toast((source || '已识别') + ' → ' + shortHost(base));
    return true;
  }

  function copyText(text) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text)
        .then(() => toast('链接已复制，发给朋友即可加入'), () => fallbackCopy(text));
    } else fallbackCopy(text);
  }

  function shareLink() {
    if (navigator.share) {
      navigator.share({ title: '文件共享中心', text: '加入我的共享空间', url: shareUrl() })
        .catch(() => { /* 用户取消 */ });
    } else copyText(shareUrl());
  }

  function focusHostInput() {
    switchTab('connect');
    const el = $('host-input');
    el.focus();
    el.select();
    toast('长按输入框粘贴，会自动识别并连接');
  }

  function readClipboard() {
    if (navigator.clipboard && navigator.clipboard.readText) {
      navigator.clipboard.readText().then((t) => {
        if (!t || !t.trim()) { focusHostInput(); return; }
        autoConnectFromText(t, '已从剪贴板识别');
      }).catch(() => focusHostInput());
    } else focusHostInput();
  }

  /** 从别处复制地址后回到页面，自动提示连接（需浏览器允许读剪贴板）。 */
  function maybeAutoPaste() {
    if (document.visibilityState !== 'visible' || !navigator.clipboard || !navigator.clipboard.readText) return;
    navigator.clipboard.readText().then((t) => {
      const base = parseHostText(t);
      if (!base || base === state.lastClip || base === state.base) return;
      state.lastClip = base;
      confirmBox('检测到主机地址', '剪贴板里有一台主机：' + base + '\n要连接并加入它的共享空间吗？', () => applyBase(base));
    }).catch(() => { /* 权限被拒，忽略 */ });
  }

  // ---- 扫码 ----
  function openScan() {
    $('scan-modal').hidden = false;
    const video = $('scan-video');
    const inWebView = /;\s*wv\)/i.test(navigator.userAgent);
    const canCamera = !inWebView && !!(navigator.mediaDevices && navigator.mediaDevices.getUserMedia && window.isSecureContext);
    if (!canCamera) {
      $('scan-stage').classList.add('no-camera');
      $('scan-tip').textContent = '点下方按钮拍照或从相册选二维码图片';
      $('scan-note').textContent = inWebView
        ? 'App 内请用「拍照识别」扫码，效果一样。'
        : '局域网 HTTP 下浏览器不允许直接调用摄像头，用「拍照识别」一样能扫码。';
      return;
    }
    $('scan-stage').classList.remove('no-camera');
    $('scan-tip').textContent = '将主机上的二维码放入框内';
    $('scan-note').textContent = '识别不到时，可点下方按钮拍照 / 从相册选择。';
    navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false })
      .then((stream) => {
        state.scanStream = stream;
        video.srcObject = stream;
        video.play().then(tickScan).catch(() => { });
      })
      .catch(() => {
        $('scan-stage').classList.add('no-camera');
        $('scan-tip').textContent = '摄像头不可用，请用下方按钮拍照识别';
      });
  }

  function tickScan() {
    if ($('scan-modal').hidden || !state.scanStream) return;
    const video = $('scan-video');
    if (video.readyState >= 2 && video.videoWidth) {
      const w = 640;
      const h = Math.round(640 * video.videoHeight / video.videoWidth);
      const cv = document.createElement('canvas');
      cv.width = w; cv.height = h;
      const ctx = cv.getContext('2d', { willReadFrequently: true });
      ctx.drawImage(video, 0, 0, w, h);
      const img = ctx.getImageData(0, 0, w, h);
      const code = window.jsQR && window.jsQR(img.data, w, h, { inversionAttempts: 'dontInvert' });
      if (code && code.data) { onQrDecoded(code.data); return; }
    }
    state.scanRaf = requestAnimationFrame(tickScan);
  }

  function closeScan() {
    $('scan-modal').hidden = true;
    cancelAnimationFrame(state.scanRaf);
    if (state.scanStream) {
      state.scanStream.getTracks().forEach((t) => t.stop());
      state.scanStream = null;
    }
    $('scan-video').srcObject = null;
    $('scan-file').value = '';
  }

  function decodeQrFile(file) {
    if (!file) return;
    if (typeof window.jsQR !== 'function') { toast('二维码识别组件未加载'); return; }
    const reader = new FileReader();
    reader.onload = () => {
      const img = new Image();
      img.onload = () => {
        const scale = Math.min(1, 1200 / Math.max(img.width, img.height));
        const w = Math.round(img.width * scale);
        const h = Math.round(img.height * scale);
        const cv = document.createElement('canvas');
        cv.width = w; cv.height = h;
        const ctx = cv.getContext('2d', { willReadFrequently: true });
        ctx.drawImage(img, 0, 0, w, h);
        let code = null;
        try {
          const data = ctx.getImageData(0, 0, w, h);
          code = window.jsQR(data.data, w, h, { inversionAttempts: 'attemptBoth' });
        } catch (e) { /* ignore */ }
        if (!code || !code.data) { toast('没识别到二维码，请换张更清晰的图片'); return; }
        onQrDecoded(code.data);
      };
      img.onerror = () => toast('图片读取失败');
      img.src = String(reader.result);
    };
    reader.onerror = () => toast('图片读取失败');
    reader.readAsDataURL(file);
  }

  function onQrDecoded(text) {
    const base = parseHostText(text);
    closeScan();
    if (!base) { toast('二维码里没有可用的主机地址'); return; }
    confirmBox('扫码连接', '识别到主机：' + base + '，要连接并加入它的共享空间吗？', () => applyBase(base));
  }

  // ---- 局域网主机发现 ----
  const FALLBACK_PORTS = '5000,5001,8000,8080';

  /** 扫描端口 = 输入框自定义 + 当前主机端口（自动加入，避免漏掉自己）。 */
  function scanPorts() {
    const set = new Set();
    const raw = $('discover-ports').value || FALLBACK_PORTS;
    raw.split(/[,，\s]+/).forEach((s) => {
      const n = parseInt(s, 10);
      if (n > 0 && n < 65536) set.add(n);
    });
    try {
      const cur = parseInt(new URL(state.base).port, 10);
      if (cur > 0) set.add(cur);
    } catch (e) { /* ignore */ }
    return Array.from(set).slice(0, 12);
  }

  function fetchJson(url, ms) {
    const ctrl = new AbortController();
    const work = fetch(url, { signal: ctrl.signal, cache: 'no-store' })
      .then((r) => {
        if (!r.ok) return { reached: true, json: null };
        return r.json().then(
          (j) => ({ reached: true, json: j }),
          () => ({ reached: true, json: null }));
      })
      .catch(() => ({ reached: false, json: null }));
    // 硬超时：即使响应体挂起，也必须让这一批 Promise.all 继续往下走
    let timer;
    const guard = new Promise((resolve) => {
      timer = setTimeout(() => {
        try { ctrl.abort(); } catch (e) { /* ignore */ }
        resolve({ reached: false, json: null, timeout: true });
      }, ms);
    });
    return Promise.race([work, guard]).then((v) => { clearTimeout(timer); return v; });
  }

  /** 新版本用 /health；老 PC 桌面版没有该接口，回退探测 /files。 */
  function probeHost(url) {
    return fetchJson(url + '/health', 900).then((h) => {
      if (h.json && h.json.ok) {
        return { app: h.json.app || '文件共享中心', items: h.json.items, online: h.json.online };
      }
      if (!h.reached) return null;   // 网络不通就没必要再试第二个接口
      return fetchJson(url + '/files', 900).then((f) => Array.isArray(f.json)
        ? { app: '文件共享中心（PC 端）', items: f.json.length, online: null }
        : null);
    });
  }

  function discoverHosts() {
    if (state.discoverRunning) return;
    const ip = state.lanIp || (location.hostname.match(/^\d{1,3}(?:\.\d{1,3}){3}$/) ? location.hostname : null);
    if (!ip) { toast('拿不到局域网 IP，请改用扫码或手动输入'); return; }
    const prefix = ip.split('.').slice(0, 3).join('.');
    const ports = scanPorts();
    if (!ports.length) { toast('请填写有效的端口'); return; }

    state.discoverRunning = true;
    state.discoverScanned = 0;
    $('discover-result').hidden = false;
    $('discover-list').textContent = '';
    $('discover-status').textContent = '正在搜索 ' + prefix + '.1~254 · 端口 ' + ports.join('/') + ' …';

    // 看门狗：个别地址可能让底层连接长时间挂起，保证扫描一定能结束
    clearTimeout(state.discoverWatchdog);
    state.discoverWatchdog = setTimeout(() => {
      if (!state.discoverRunning) return;
      $('discover-status').textContent = found.length
        ? '扫描结束，找到 ' + found.length + ' 台（部分地址无响应，可缩小端口范围重试）'
        : '扫描结束，未找到主机（可缩小端口范围重试，或用扫码 / 手动输入）';
      stopDiscover(false);
    }, 45000);

    const found = [];
    const queue = [];
    for (let i = 1; i <= 254; i++) queue.push(prefix + '.' + i);
    const total = queue.length;
    let cursor = 0, active = 0;
    const concurrency = 16;   // 每个 IP 并行探测多个端口，降低 IP 并发避免请求风暴

    const renderFound = (d, url) => {
      const row = document.createElement('div');
      row.className = 'discover-item';
      const info = document.createElement('div');
      info.className = 'd-info';
      const strong = document.createElement('strong');
      strong.textContent = url.replace(/^https?:\/\//, '');
      const small = document.createElement('small');
      small.textContent = (d.app || '文件共享中心') + ' · ' + (d.items || 0) + ' 项'
        + (d.online != null ? ' · ' + d.online + ' 人在线' : '');
      info.append(strong, small);
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.textContent = '连接';
      btn.addEventListener('click', () => { stopDiscover(); applyBase(url); });
      row.append(info, btn);
      $('discover-list').appendChild(row);
    };

    const next = () => {
      if (!state.discoverRunning) return;
      if (cursor >= total && active === 0) {
        $('discover-status').textContent = found.length
          ? '找到 ' + found.length + ' 台主机（已扫 ' + ports.join('/') + '）'
          : '没找到其他主机：确认同一 WiFi、对方已启动，或调整端口后重新搜索';
        stopDiscover(false);
        return;
      }
      while (state.discoverRunning && active < concurrency && cursor < total) {
        const ipx = queue[cursor++];
        active++;
        Promise.all(ports.map((p) => {
          const url = 'http://' + ipx + ':' + p;
          if (url === state.base) return Promise.resolve(null);
          return probeHost(url).then((d) => d ? { url: url, d: d } : null);
        })).then((hits) => {
          active--;
          state.discoverScanned++;
          if (state.discoverRunning) {
            hits.filter(Boolean).forEach((hit) => { found.push(hit.url); renderFound(hit.d, hit.url); });
          }
          if (state.discoverScanned % 8 === 0 || state.discoverScanned === total) {
            $('discover-status').textContent = '已探测 ' + state.discoverScanned + '/' + total
              + ' 个 IP，找到 ' + found.length + ' 台…';
          }
          next();
        });
      }
    };
    next();
  }

  function stopDiscover(clear) {
    state.discoverRunning = false;
    clearTimeout(state.discoverWatchdog);
    state.discoverWatchdog = null;
    if (clear !== false) $('discover-status').textContent = '已停止';
  }

  // ---------------------------------------------------------------- 文件列表
  function loadFiles(showToast) {
    return api('/files').then((list) => {
      state.files = Array.isArray(list) ? list : [];
      state.files.forEach((f, i) => { f._i = i; });
      state.selected.clear();
      renderFiles();
      if (showToast) toast('已刷新，共 ' + state.files.length + ' 项');
      checkHealth();
    }).catch(() => {
      if (!state.files.length) {
        $('file-list').innerHTML = '';
        $('empty-state').hidden = false;
        $('empty-state').querySelector('p').textContent = '连不上主机';
        $('empty-state').querySelector('span').textContent = '去「连接」页检查主机地址，确认服务端已启动';
      }
    });
  }

  function renderFiles() {
    const q = state.query.trim().toLowerCase();
    const list = q ? state.files.filter((f) => f.name.toLowerCase().includes(q)) : state.files;
    const ul = $('file-list');
    ul.classList.toggle('manage-mode', state.manage);
    $('bulk-bar').hidden = !state.manage;
    $('file-count').textContent = state.files.length;
    $('empty-state').hidden = list.length > 0;
    $('empty-state').querySelector('p').textContent = q ? '没有匹配的文件' : '共享空间还是空的';
    $('empty-state').querySelector('span').textContent = q ? '换个关键词试试' : '点上面的「选择文件」上传第一个文件吧';
    $('list-footer').hidden = list.length === 0;

    const total = state.files.reduce((s, f) => s + (f.bytes || 0), 0);
    $('list-footer').textContent = '共 ' + state.files.length + ' 项 · ' + humanSize(total) + ' · 下拉可刷新';

    ul.innerHTML = list.map((f) => {
      const ic = iconFor(f);
      const checked = state.selected.has(f.name) ? 'checked' : '';
      const sub = f.type === 'folder'
        ? (f.file_count || 0) + ' 个文件 · ' + f.size
        : f.size;
      return '<li class="file-item' + (state.selected.has(f.name) ? ' selected' : '') + '" data-i="' + f._i + '">' +
        '<input class="item-check" type="checkbox" ' + checked + ' data-act="check" aria-label="选择">' +
        '<div class="file-icon ' + ic.cls + '">' + ic.emoji + '</div>' +
        '<div class="file-main">' +
          '<div class="file-name" title="' + esc(f.name) + '">' + esc(f.name) + '</div>' +
          '<div class="file-meta"><span>' + esc(sub) + '</span><span>' + esc(f.modified_str || '') + '</span></div>' +
        '</div>' +
        '<div class="item-actions">' +
          '<button class="act dl" data-act="download" type="button" aria-label="下载">' + ICON_DOWNLOAD + '</button>' +
          '<button class="act del" data-act="delete" type="button" aria-label="删除">' + ICON_TRASH + '</button>' +
        '</div></li>';
    }).join('');
    updateBulkCount();
  }

  function humanSize(n) {
    if (n < 1024) return n + ' B';
    if (n < 1048576) return (n / 1024).toFixed(2) + ' KB';
    if (n < 1073741824) return (n / 1048576).toFixed(2) + ' MB';
    return (n / 1073741824).toFixed(2) + ' GB';
  }

  function updateBulkCount() {
    $('bulk-count').textContent = '已选 ' + state.selected.size + ' 项';
    const all = state.files.length > 0 && state.selected.size === state.files.length;
    $('check-all').checked = all;
  }

  function toggleSelect(name) {
    if (state.selected.has(name)) state.selected.delete(name);
    else state.selected.add(name);
    renderFiles();
  }

  function openItem(item) {
    if (item.type === 'folder') {
      triggerDownload(fileUrl(item.name), item.name + '.zip');
      toast('文件夹正在打包下载');
      return;
    }
    const e = extOf(item.name);
    if (IMAGE_EXT.includes(e) || VIDEO_EXT.includes(e) || AUDIO_EXT.includes(e) || e === 'pdf' || e === 'txt') {
      showPreview(item, e);
    } else {
      triggerDownload(fileUrl(item.name), item.name);
      toast('开始下载 ' + item.name);
    }
  }

  function showPreview(item, e) {
    const url = fileUrl(item.name, true);
    let html;
    if (IMAGE_EXT.includes(e)) html = '<img src="' + esc(url) + '" alt="预览">';
    else if (VIDEO_EXT.includes(e)) html = '<video src="' + esc(url) + '" controls playsinline style="max-width:100%;max-height:62vh"></video>';
    else if (AUDIO_EXT.includes(e)) html = '<audio src="' + esc(url) + '" controls style="width:100%;margin:40px 0"></audio>';
    else html = '<iframe src="' + esc(url) + '" style="width:100%;height:62vh;border:0;border-radius:8px"></iframe>';
    $('preview-body').innerHTML = html;
    $('preview-name').textContent = item.name;
    $('preview-modal').hidden = false;
  }

  function confirmBox(title, text, cb) {
    $('confirm-title').textContent = title;
    $('confirm-text').textContent = text;
    state.confirmCb = cb;
    $('confirm-modal').hidden = false;
  }

  function deleteNames(names) {
    return api('/delete-selected', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ names: names }),
    }).then((d) => {
      toast(d.message || '已删除');
      loadFiles();
    }).catch(() => toast('删除失败，请检查主机连接'));
  }

  // ---------------------------------------------------------------- 上传
  function uploadFiles(files, isFolder) {
    files = Array.from(files || []).filter(Boolean);
    if (!files.length) return;
    const fd = new FormData();
    let endpoint = '/upload';
    let label;

    if (isFolder) {
      endpoint = '/upload-folder';
      const first = files[0].webkitRelativePath || files[0].name;
      const root = first.split('/')[0] || '上传文件夹';
      fd.append('folder_name', root);
      files.forEach((f) => {
        const parts = (f.webkitRelativePath || f.name).split('/');
        const rel = parts.slice(1).join('/') || f.name;
        fd.append('files[]', f, rel);
      });
      label = '文件夹「' + root + '」（' + files.length + ' 个文件）';
    } else {
      files.forEach((f) => fd.append('file', f, f.name));
      label = files.length === 1 ? files[0].name : files.length + ' 个文件';
    }

    const wrap = $('progress-wrap');
    wrap.hidden = false;
    $('progress-bar').style.width = '0%';
    $('progress-text').textContent = '0%';

    const xhr = new XMLHttpRequest();
    xhr.open('POST', state.base + endpoint);
    xhr.upload.onprogress = (e) => {
      if (!e.lengthComputable) return;
      const pct = Math.round(e.loaded / e.total * 100);
      $('progress-bar').style.width = pct + '%';
      $('progress-text').textContent = pct + '%';
    };
    xhr.onload = () => {
      wrap.hidden = true;
      let res = {};
      try { res = JSON.parse(xhr.responseText); } catch (e) { /* ignore */ }
      if (xhr.status >= 200 && xhr.status < 300 && res.success) {
        toast('上传成功：' + label);
        loadFiles();
        notifyShared('分享了 ' + label);
      } else {
        toast('上传失败：' + (res.message || xhr.status));
      }
    };
    xhr.onerror = () => { wrap.hidden = true; toast('上传失败，主机不可达'); };
    xhr.send(fd);
  }

  function notifyShared(text) {
    appendBubble({ type: 'file_shared', user_id: state.myId, nick: state.nick, message: text, mine: true });
    sendWS({ type: 'file_shared', message: text });
  }

  // ---------------------------------------------------------------- 群聊
  function wsUrl() {
    const u = new URL(state.base);
    u.protocol = u.protocol === 'https:' ? 'wss:' : 'ws:';
    u.pathname = '/chat';
    u.search = '?nick=' + encodeURIComponent(state.nick);
    return u.toString();
  }

  function connectWS() {
    clearTimeout(state.wsTimer);
    if (state.ws) {
      try { state.ws.onclose = null; state.ws.close(); } catch (e) { /* ignore */ }
      state.ws = null;
    }
    let ws;
    try { ws = new WebSocket(wsUrl()); } catch (e) { scheduleReconnect(); return; }
    state.ws = ws;

    ws.onopen = () => {
      state.wsRetry = 0;
      setStatus(true, '已连接');
    };
    ws.onmessage = (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch (err) { return; }
      handleMessage(msg);
    };
    ws.onclose = () => {
      setStatus(false, '已断开');
      scheduleReconnect();
    };
    ws.onerror = () => { /* onclose 统一处理 */ };
  }

  function scheduleReconnect() {
    clearTimeout(state.wsTimer);
    state.wsRetry = Math.min(state.wsRetry + 1, 6);
    const delay = Math.min(1000 * Math.pow(1.6, state.wsRetry), 15000);
    state.wsTimer = setTimeout(connectWS, delay);
  }

  function sendWS(obj) {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) {
      state.ws.send(JSON.stringify(obj));
      return true;
    }
    return false;
  }

  function handleMessage(msg) {
    if (msg.type === 'welcome') {
      state.myId = msg.user_id;
      state.online = msg.online_count || 0;
      $('online-count').textContent = state.online;
      $('chat-hint').textContent = (msg.users || []).length
        ? '在线：' + msg.users.slice(0, 3).join('、') + ((msg.users.length > 3) ? ' 等' : '')
        : '消息实时送达同一共享空间';
      $('chat-messages').textContent = '';
      appendSystem('已连接到共享空间');
      return;
    }
    if (msg.type === 'system') {
      state.online = msg.online_count != null ? msg.online_count : state.online;
      $('online-count').textContent = state.online;
      appendSystem(msg.message);
      return;
    }
    if (msg.type === 'files_changed') { loadFiles(); return; }
    if (msg.type === 'chat' || msg.type === 'file_shared') {
      appendBubble(msg);
      if (state.tab !== 'chat') {
        state.unread++;
        $('unread-badge').hidden = false;
      }
    }
  }

  function timeStr(iso) {
    if (!iso) return '';
    try { return new Date(iso).toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' }); }
    catch (e) { return ''; }
  }

  function scrollChat() {
    const box = $('chat-scroll');
    requestAnimationFrame(() => { box.scrollTop = box.scrollHeight; });
  }

  function appendSystem(text) {
    const el = document.createElement('div');
    el.className = 'msg-system';
    el.textContent = text;
    $('chat-messages').appendChild(el);
    scrollChat();
  }

  function appendBubble(msg) {
    const mine = msg.mine || (state.myId && msg.user_id === state.myId);
    const row = document.createElement('div');
    row.className = 'msg-row' + (mine ? ' mine' : '');
    const nick = document.createElement('div');
    nick.className = 'msg-nick';
    nick.textContent = mine ? '我' : (msg.nick || msg.user_id || '匿名设备');
    const bubble = document.createElement('div');
    bubble.className = 'bubble' + (msg.type === 'file_shared' ? ' shared' : '');
    bubble.textContent = msg.message || '';
    const time = document.createElement('div');
    time.className = 'msg-time';
    time.textContent = timeStr(msg.timestamp) || '刚刚';
    row.append(nick, bubble, time);
    $('chat-messages').appendChild(row);
    while ($('chat-messages').children.length > 200) $('chat-messages').firstChild.remove();
    scrollChat();
  }

  function sendChat() {
    const input = $('chat-input');
    const text = input.value.trim();
    if (!text) return;
    if (!sendWS({ type: 'chat', message: text })) { toast('群聊未连接，正在重连…'); return; }
    appendBubble({ type: 'chat', user_id: state.myId, nick: state.nick, message: text, mine: true, timestamp: new Date().toISOString() });
    input.value = '';
  }

  // ---------------------------------------------------------------- Tab / 事件
  function switchTab(name) {
    state.tab = name;
    document.querySelectorAll('.panel').forEach((p) => p.classList.toggle('active', p.id === 'panel-' + name));
    document.querySelectorAll('.tab').forEach((t) => t.classList.toggle('active', t.dataset.tab === name));
    if (name === 'chat') { state.unread = 0; $('unread-badge').hidden = true; scrollChat(); }
    if (name === 'connect') checkHealth();
    window.scrollTo(0, 0);
  }

  function bind() {
    document.querySelectorAll('.tab').forEach((t) => t.addEventListener('click', () => switchTab(t.dataset.tab)));

    $('btn-pick-files').addEventListener('click', () => $('input-files').click());
    $('btn-pick-folder').addEventListener('click', () => $('input-folder').click());
    $('btn-pick-camera').addEventListener('click', () => $('input-camera').click());
    $('input-files').addEventListener('change', (e) => { uploadFiles(e.target.files, false); e.target.value = ''; });
    $('input-folder').addEventListener('change', (e) => { uploadFiles(e.target.files, true); e.target.value = ''; });
    $('input-camera').addEventListener('change', (e) => { uploadFiles(e.target.files, false); e.target.value = ''; });

    $('btn-refresh').addEventListener('click', () => loadFiles(true));
    $('btn-manage').addEventListener('click', () => {
      state.manage = !state.manage;
      state.selected.clear();
      $('btn-manage').textContent = state.manage ? '完成' : '管理';
      renderFiles();
    });
    $('search-input').addEventListener('input', (e) => { state.query = e.target.value; renderFiles(); });

    $('file-list').addEventListener('click', (e) => {
      const li = e.target.closest('.file-item');
      if (!li) return;
      const item = state.files[Number(li.dataset.i)];
      if (!item) return;
      const act = e.target.closest('[data-act]');
      const action = act ? act.dataset.act : null;
      if (action === 'check' || (state.manage && !action)) { toggleSelect(item.name); return; }
      if (action === 'download') {
        triggerDownload(fileUrl(item.name), item.name);
        toast(item.type === 'folder' ? '文件夹正在打包下载' : '开始下载');
        return;
      }
      if (action === 'delete') {
        confirmBox('删除文件', '确定删除「' + item.name + '」吗？此操作不可恢复。', () => deleteNames([item.name]));
        return;
      }
      if (!action) openItem(item);
    });

    $('check-all').addEventListener('change', (e) => {
      state.selected.clear();
      if (e.target.checked) state.files.forEach((f) => state.selected.add(f.name));
      renderFiles();
    });
    $('btn-bulk-download').addEventListener('click', () => {
      if (!state.selected.size) { toast('请先选择项目'); return; }
      const p = new URLSearchParams();
      state.selected.forEach((n) => p.append('name', n));
      triggerDownload(state.base + '/download-selected?' + p.toString(), '共享文件.zip');
      toast('正在打包 ' + state.selected.size + ' 项');
    });
    $('btn-bulk-delete').addEventListener('click', () => {
      if (!state.selected.size) { toast('请先选择项目'); return; }
      const names = Array.from(state.selected);
      confirmBox('批量删除', '确定删除选中的 ' + names.length + ' 个项目吗？此操作不可恢复。', () => deleteNames(names));
    });

    $('btn-send').addEventListener('click', sendChat);
    $('chat-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); sendChat(); } });

    $('btn-connect').addEventListener('click', () => connectHost($('host-input').value));
    $('host-input').addEventListener('keydown', (e) => { if (e.key === 'Enter') connectHost(e.target.value); });
    $('host-input').addEventListener('input', (e) => {
      clearTimeout(state.hostInputTimer);
      const v = e.target.value;
      if (!v || !/https?:\/\/|\d{1,3}(?:\.\d{1,3}){3}/.test(v)) return;
      state.hostInputTimer = setTimeout(() => {
        const base = parseHostText(v);
        if (base && base !== state.base) autoConnectFromText(v, '已自动识别');
      }, 450);
    });
    $('btn-use-self').addEventListener('click', () => applyBase(location.origin));
    $('btn-save-nick').addEventListener('click', () => {
      const nick = $('nick-input').value.trim().slice(0, 20);
      if (!nick) { toast('昵称不能为空'); return; }
      state.nick = nick;
      writeStore(LS.nick, nick);
      connectWS();
      toast('昵称已保存');
    });
    $('btn-copy-link').addEventListener('click', () => copyText(shareUrl()));
    $('btn-share-link').addEventListener('click', shareLink);
    $('btn-share').addEventListener('click', shareLink);
    $('btn-clipboard').addEventListener('click', readClipboard);
    $('btn-scan').addEventListener('click', openScan);
    $('btn-discover').addEventListener('click', () => {
      if (state.discoverRunning) stopDiscover(); else discoverHosts();
    });
    $('btn-discover-stop').addEventListener('click', () => stopDiscover());
    $('btn-discover-retry').addEventListener('click', () => { stopDiscover(); discoverHosts(); });
    $('scan-close').addEventListener('click', closeScan);
    $('scan-modal').querySelector('.modal-mask').addEventListener('click', closeScan);
    $('btn-scan-photo').addEventListener('click', () => $('scan-file').click());
    $('scan-file').addEventListener('change', (e) => decodeQrFile(e.target.files[0]));
    $('status-chip').addEventListener('click', () => switchTab('connect'));

    // 页面任意位置粘贴含地址的文本 → 自动识别并连接
    document.addEventListener('paste', (e) => {
      const cd = e.clipboardData || window.clipboardData;
      const text = cd ? cd.getData('text') : '';
      if (!text) return;
      const tag = (e.target && e.target.tagName || '').toLowerCase();
      if (tag === 'input' || tag === 'textarea') return;
      if (parseHostText(text)) { e.preventDefault(); autoConnectFromText(text, '已从剪贴板识别'); }
    });

    $('confirm-cancel').addEventListener('click', () => { $('confirm-modal').hidden = true; state.confirmCb = null; });
    $('confirm-ok').addEventListener('click', () => {
      $('confirm-modal').hidden = true;
      const cb = state.confirmCb;
      state.confirmCb = null;
      if (cb) cb();
    });
    $('confirm-modal').querySelector('.modal-mask').addEventListener('click', () => { $('confirm-modal').hidden = true; });
    $('preview-close').addEventListener('click', () => { $('preview-modal').hidden = true; $('preview-body').textContent = ''; });
    $('preview-modal').querySelector('.modal-mask').addEventListener('click', () => { $('preview-modal').hidden = true; $('preview-body').textContent = ''; });

    window.addEventListener('beforeinstallprompt', (e) => {
      e.preventDefault();
      state.installPrompt = e;
      $('btn-install').hidden = false;
    });
    $('btn-install').addEventListener('click', () => {
      if (!state.installPrompt) return;
      state.installPrompt.prompt();
      state.installPrompt.userChoice.then(() => { state.installPrompt = null; $('btn-install').hidden = true; });
    });

    // 下拉刷新（文件页，页面在顶部时）
    let startY = 0;
    document.addEventListener('touchstart', (e) => {
      startY = (window.scrollY <= 0 && state.tab === 'files') ? e.touches[0].clientY : 0;
    }, { passive: true });
    document.addEventListener('touchend', (e) => {
      if (startY && e.changedTouches[0].clientY - startY > 80) loadFiles(true);
      startY = 0;
    }, { passive: true });

    if ('serviceWorker' in navigator) {
      window.addEventListener('load', () => {
        navigator.serviceWorker.register('/sw.js').catch(() => { /* 忽略：不影响使用 */ });
      });
    }

    // 从别处复制地址后切回页面，提示一键连接
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') setTimeout(maybeAutoPaste, 350);
    });
  }

  function fallbackCopy(text) {
    const ta = document.createElement('textarea');
    ta.value = text;
    ta.style.position = 'fixed';
    ta.style.opacity = '0';
    document.body.appendChild(ta);
    ta.select();
    try { document.execCommand('copy'); toast('链接已复制'); } catch (e) { toast('复制失败，请手动复制：' + text); }
    ta.remove();
  }

  // ---------------------------------------------------------------- 启动
  function init() {
    // 扫码进入：URL 里的 host 参数自动设为目标主机
    const params = new URLSearchParams(location.search);
    const fromQR = params.get('host');
    if (fromQR) {
      const b = normalizeBase(fromQR);
      if (b) { writeStore(LS.base, b); rememberHost(b); }
      try { history.replaceState(null, '', location.pathname); } catch (e) { /* ignore */ }
    }

    state.base = normalizeBase(readStore(LS.base, '')) || location.origin;
    state.nick = readStore(LS.nick, '');
    if (!state.nick) {
      const ua = navigator.userAgent;
      const device = /iPhone|iPad/.test(ua) ? 'iPhone' : (/Android/.test(ua) ? '安卓' : '设备');
      state.nick = device + '-' + Math.random().toString(36).slice(2, 6);
      writeStore(LS.nick, state.nick);
    }
    $('nick-input').value = state.nick;

    bind();
    applyBase(state.base, true);
    appendSystem('欢迎来到共享空间，发送消息试试吧');
    // 深链：?tab=files|chat|connect，可用于 PWA 快捷方式
    const initialTab = params.get('tab');
    if (initialTab && ['files', 'chat', 'connect'].indexOf(initialTab) >= 0) switchTab(initialTab);
    setInterval(() => { if (document.visibilityState === 'visible') checkHealth(); }, 30000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
