//! 文件共享中心 · PC 端（Rust）
//! 单文件 exe：移动端前端用 rust-embed 编进二进制，运行时只需 download/ 目录。
//! API 与 Python 版 server.py / Android / iOS 内嵌服务完全一致。
//! 发布构建隐藏控制台，改由 egui 图形启动器显示状态。

// 双击运行不弹黑色控制台窗口（--no-gui 仍可作为后台服务）
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod launcher;

use axum::body::Body;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Multipart, Path, Query, RawQuery, State};
use axum::http::header::{HeaderValue, CONTENT_DISPOSITION, CONTENT_LENGTH, CONTENT_TYPE};
use axum::http::{header, StatusCode, Uri};
use axum::response::{IntoResponse, Json, Response};
use axum::routing::{delete, get, post};
use axum::Router;
use chrono::Local;
use rust_embed::RustEmbed;
use serde::Serialize;
use serde_json::json;
use std::collections::{HashMap, VecDeque};
use std::net::{SocketAddr, UdpSocket};
use std::path::{Path as FsPath, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tokio::io::AsyncWriteExt;
use tokio::sync::{mpsc, Mutex};
use tokio_util::io::ReaderStream;
use tower_http::cors::{Any, CorsLayer};
use zip::write::FileOptions;
use zip::CompressionMethod;

#[derive(RustEmbed)]
#[folder = "static/"]
struct Assets;

// ---------------------------------------------------------------- 状态

type ClientMap = HashMap<u64, (String, mpsc::UnboundedSender<String>)>;

struct WsHub {
    clients: Mutex<ClientMap>,
    history: Mutex<VecDeque<String>>,
    next_id: AtomicU64,
}

impl WsHub {
    fn new() -> Self {
        Self {
            clients: Mutex::new(HashMap::new()),
            history: Mutex::new(VecDeque::with_capacity(100)),
            next_id: AtomicU64::new(1),
        }
    }

    async fn join(&self, nick: String, tx: mpsc::UnboundedSender<String>) -> (u64, Vec<String>) {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut clients = self.clients.lock().await;
        clients.insert(id, (nick, tx));
        let history = self.history.lock().await.iter().cloned().collect();
        (id, history)
    }

    async fn leave(&self, id: u64) {
        self.clients.lock().await.remove(&id);
    }

    async fn online(&self) -> usize {
        self.clients.lock().await.len()
    }

    /// 供图形界面同步轮询，锁被占用时返回 0，不阻塞窗口绘制。
    pub fn try_online(&self) -> usize {
        self.clients.try_lock().map(|c| c.len()).unwrap_or(0)
    }

    async fn users(&self) -> Vec<String> {
        self.clients.lock().await.values().map(|(n, _)| n.clone()).collect()
    }

    async fn push_history(&self, msg: String) {
        let mut h = self.history.lock().await;
        if h.len() >= 100 {
            h.pop_front();
        }
        h.push_back(msg);
    }

    async fn broadcast(&self, msg: String, exclude: Option<u64>) {
        let clients = self.clients.lock().await;
        for (id, (_, tx)) in clients.iter() {
            if Some(*id) == exclude {
                continue;
            }
            let _ = tx.send(msg.clone());
        }
    }
}

#[derive(Clone)]
struct AppState {
    share_dir: PathBuf,
    temp_dir: PathBuf,
    port: u16,
    hub: Arc<WsHub>,
}

// ---------------------------------------------------------------- 工具

fn human_size(n: u64) -> String {
    if n < 1024 { format!("{} B", n) }
    else if n < 1024 * 1024 { format!("{:.2} KB", n as f64 / 1024.0) }
    else if n < 1024 * 1024 * 1024 { format!("{:.2} MB", n as f64 / 1048576.0) }
    else { format!("{:.2} GB", n as f64 / 1073741824.0) }
}

fn now_iso() -> String {
    Local::now().format("%Y-%m-%dT%H:%M:%S").to_string()
}

fn modified_str(time: std::time::SystemTime) -> String {
    let dt: chrono::DateTime<Local> = time.into();
    dt.format("%Y-%m-%d %H:%M").to_string()
}

fn lan_ip() -> String {
    match UdpSocket::bind("0.0.0.0:0") {
        Ok(s) => {
            if s.connect("8.8.8.8:80").is_ok() {
                if let Ok(addr) = s.local_addr() {
                    return addr.ip().to_string();
                }
            }
        }
        Err(_) => {}
    }
    "127.0.0.1".to_string()
}

fn safe_basename(raw: &str) -> Option<String> {
    let name = raw.replace('\\', "/");
    let name = name.rsplit('/').next().unwrap_or("").trim();
    let cleaned: String = name
        .chars()
        .map(|c| {
            if "<>:\"|?*".contains(c) || c.is_control() { '_' } else { c }
        })
        .collect();
    let cleaned = cleaned.trim_end_matches('.').trim();
    if cleaned.is_empty() || cleaned == "." || cleaned == ".." {
        return None;
    }
    Some(cleaned.chars().take(200).collect())
}

/// 已存在路径的校验：拒绝 .. / 绝对路径 / 越出共享目录。
fn resolve_existing(base: &FsPath, raw: &str) -> Option<PathBuf> {
    if raw.is_empty() || raw.starts_with('/') || raw.contains(':') {
        return None;
    }
    let mut p = base.to_path_buf();
    for seg in raw.replace('\\', "/").split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." {
            return None;
        }
        p.push(seg);
    }
    let root = std::fs::canonicalize(base).ok()?;
    let target = std::fs::canonicalize(&p).ok()?;
    if !target.starts_with(&root) {
        return None;
    }
    Some(p)
}

/// 新文件路径的校验（上传目标可能还不存在）。
fn resolve_new(base: &FsPath, raw: &str) -> Option<PathBuf> {
    if raw.is_empty() || raw.starts_with('/') || raw.contains(':') {
        return None;
    }
    let mut p = base.to_path_buf();
    for seg in raw.replace('\\', "/").split('/') {
        if seg.is_empty() || seg == "." {
            continue;
        }
        if seg == ".." || seg.contains('\0') {
            return None;
        }
        p.push(seg);
    }
    if !p.starts_with(base) {
        return None;
    }
    Some(p)
}

fn mime_of(name: &str) -> &'static str {
    let n = name.to_ascii_lowercase();
    if n.ends_with(".html") || n.ends_with(".htm") { "text/html; charset=utf-8" }
    else if n.ends_with(".js") { "application/javascript; charset=utf-8" }
    else if n.ends_with(".css") { "text/css; charset=utf-8" }
    else if n.ends_with(".json") || n.ends_with(".webmanifest") { "application/manifest+json; charset=utf-8" }
    else if n.ends_with(".png") { "image/png" }
    else if n.ends_with(".jpg") || n.ends_with(".jpeg") { "image/jpeg" }
    else if n.ends_with(".gif") { "image/gif" }
    else if n.ends_with(".svg") { "image/svg+xml" }
    else if n.ends_with(".pdf") { "application/pdf" }
    else if n.ends_with(".txt") || n.ends_with(".md") { "text/plain; charset=utf-8" }
    else if n.ends_with(".mp4") { "video/mp4" }
    else if n.ends_with(".mp3") { "audio/mpeg" }
    else if n.ends_with(".zip") { "application/zip" }
    else { "application/octet-stream" }
}

fn url_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match *b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                continue;
            }
        }
        // URL 查询里的 + 视为空格
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

#[derive(Serialize)]
struct FileInfo {
    name: String,
    size: String,
    bytes: u64,
    modified: f64,
    modified_str: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    file_count: Option<usize>,
}

fn dir_stats(dir: &FsPath) -> (u64, usize) {
    let mut size = 0u64;
    let mut count = 0usize;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            if let Ok(meta) = e.metadata() {
                if meta.is_dir() {
                    let (s, c) = dir_stats(&e.path());
                    size += s;
                    count += c;
                } else {
                    size += meta.len();
                    count += 1;
                }
            }
        }
    }
    (size, count)
}

fn item_info(path: &FsPath) -> Option<FileInfo> {
    let meta = std::fs::metadata(path).ok()?;
    let name = path.file_name()?.to_string_lossy().into_owned();
    let modified = meta
        .modified()
        .ok()?
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();
    let is_dir = meta.is_dir();
    let (bytes, file_count) = if is_dir {
        let (s, c) = dir_stats(path);
        (s, Some(c))
    } else {
        (meta.len(), None)
    };
    Some(FileInfo {
        name,
        size: human_size(bytes),
        bytes,
        modified,
        modified_str: modified_str(meta.modified().ok()?),
        kind: if is_dir { "folder".into() } else { "file".into() },
        file_count,
    })
}

// ---------------------------------------------------------------- 路由

async fn serve_asset(uri: Uri) -> Response {
    let mut key = uri.path().trim_start_matches('/').to_string();
    if key.is_empty() {
        key = "index.html".to_string();
    }
    if let Some(rest) = key.strip_prefix("static/") {
        key = rest.to_string();
    }
    if key == "favicon.ico" {
        key = "icon-192.png".to_string();
    }
    match Assets::get(&key) {
        Some(content) => {
            let mime = mime_of(&key);
            Response::builder()
                .status(StatusCode::OK)
                .header(CONTENT_TYPE, HeaderValue::from_static(mime))
                .header(header::CACHE_CONTROL, HeaderValue::from_static("no-cache"))
                .body(Body::from(content.data.into_owned()))
                .unwrap()
        }
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn health(State(st): State<AppState>) -> Response {
    let count = std::fs::read_dir(&st.share_dir).map(|r| r.count()).unwrap_or(0);
    Json(json!({
        "ok": true,
        "app": "文件共享中心 · 手机版",
        "version": "1.0",
        "time": now_iso(),
        "lan_ip": lan_ip(),
        "port": st.port,
        "online": st.hub.online().await,
        "items": count
    }))
    .into_response()
}

async fn list_files(State(st): State<AppState>) -> Response {
    let mut items: Vec<FileInfo> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&st.share_dir) {
        for e in entries.flatten() {
            if let Some(info) = item_info(&e.path()) {
                items.push(info);
            }
        }
    }
    items.sort_by(|a, b| {
        let ad = a.kind == "folder";
        let bd = b.kind == "folder";
        match ad.cmp(&bd) {
            std::cmp::Ordering::Equal => b.modified.partial_cmp(&a.modified).unwrap_or(std::cmp::Ordering::Equal),
            other => other.reverse(), // 文件夹排在前面
        }
    });
    Json(items).into_response()
}

struct PendingPart {
    field_name: String,
    filename: Option<String>,
    temp: PathBuf,
}

async fn collect_parts(mp: &mut Multipart, temp_dir: &FsPath) -> Result<Vec<PendingPart>, String> {
    let mut parts = Vec::new();
    while let Some(field) = mp.next_field().await.map_err(|e| e.to_string())? {
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().map(|s| s.to_string());
        let temp = temp_dir.join(format!("part_{}_{}.tmp", std::process::id(), parts.len()));
        let mut file = tokio::fs::File::create(&temp).await.map_err(|e| e.to_string())?;
        let mut field = field;
        while let Ok(Some(chunk)) = field.chunk().await {
            if let Err(e) = file.write_all(&chunk).await {
                let _ = file.flush().await;
                return Err(e.to_string());
            }
        }
        let _ = file.flush().await;
        drop(file);
        parts.push(PendingPart { field_name: name, filename, temp });
    }
    Ok(parts)
}

async fn save_part(part: &PendingPart, dest: &FsPath) -> Result<(), String> {
    let mut src = tokio::fs::File::open(&part.temp).await.map_err(|e| e.to_string())?;
    let mut out = tokio::fs::File::create(dest).await.map_err(|e| e.to_string())?;
    tokio::io::copy(&mut src, &mut out).await.map_err(|e| e.to_string())?;
    let _ = out.flush().await;
    Ok(())
}

fn unique_path(dir: &FsPath, name: &str) -> PathBuf {
    let target = dir.join(name);
    if !target.exists() {
        return target;
    }
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (name[..i].to_string(), name[i..].to_string()),
        _ => (name.to_string(), String::new()),
    };
    let mut i = 1;
    loop {
        let candidate = dir.join(format!("{}({}){}", stem, i, ext));
        if !candidate.exists() {
            return candidate;
        }
        i += 1;
    }
}

async fn upload(State(st): State<AppState>, mut mp: Multipart) -> Response {
    let parts = match collect_parts(&mut mp, &st.temp_dir).await {
        Ok(p) => p,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(json!({"success": false, "message": e}))).into_response(),
    };
    let mut saved: Vec<String> = Vec::new();
    for part in parts.iter() {
        if part.filename.is_none() {
            continue;
        }
        let raw = part.filename.clone().unwrap_or_default();
        let name = match safe_basename(&raw) {
            Some(n) => n,
            None => continue,
        };
        let dest = unique_path(&st.share_dir, &name);
        if save_part(part, &dest).await.is_ok() {
            saved.push(dest.file_name().unwrap_or_default().to_string_lossy().into_owned());
        }
    }
    for p in parts.iter() {
        let _ = tokio::fs::remove_file(&p.temp).await;
    }
    st.hub.broadcast("{\"type\":\"files_changed\"}".to_string(), None).await;
    Json(json!({
        "success": true,
        "message": format!("上传成功 {} 个文件", saved.len()),
        "filenames": saved,
        "failed": []
    }))
    .into_response()
}

async fn upload_folder(State(st): State<AppState>, mut mp: Multipart) -> Response {
    let parts = match collect_parts(&mut mp, &st.temp_dir).await {
        Ok(p) => p,
        Err(e) => return (StatusCode::BAD_REQUEST, Json(json!({"success": false, "message": e}))).into_response(),
    };
    let folder_raw = parts
        .iter()
        .find(|p| p.field_name == "folder_name" && p.filename.is_none())
        .map(|p| std::fs::read_to_string(&p.temp).unwrap_or_default().trim().to_string())
        .unwrap_or_else(|| "上传文件夹".to_string());
    let folder_name = safe_basename(&folder_raw).unwrap_or_else(|| "上传文件夹".to_string());
    let folder = unique_path(&st.share_dir, &folder_name);
    if tokio::fs::create_dir_all(&folder).await.is_err() {
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"success": false, "message": "创建文件夹失败"}))).into_response();
    }
    let mut count = 0usize;
    for part in parts.iter() {
        let raw = match &part.filename {
            Some(f) => f,
            None => continue,
        };
        let rel = raw.replace('\\', "/").trim_start_matches('/').to_string();
        let dest = match resolve_new(&folder, &rel) {
            Some(p) => p,
            None => continue,
        };
        if let Some(parent) = dest.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        if save_part(part, &dest).await.is_ok() {
            count += 1;
        }
    }
    for p in parts.iter() {
        let _ = tokio::fs::remove_file(&p.temp).await;
    }
    st.hub.broadcast("{\"type\":\"files_changed\"}".to_string(), None).await;
    Json(json!({
        "success": true,
        "message": format!("文件夹上传成功，共 {} 个文件", count),
        "folder_name": folder.file_name().unwrap_or_default().to_string_lossy()
    }))
    .into_response()
}

fn add_to_zip(
    zip: &mut zip::ZipWriter<std::fs::File>,
    path: &FsPath,
    entry: &str,
    options: FileOptions,
) -> std::io::Result<()> {
    if path.is_dir() {
        if let Ok(entries) = std::fs::read_dir(path) {
            for e in entries.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                let child = format!("{}/{}", entry, name);
                add_to_zip(zip, &e.path(), &child, options.clone())?;
            }
        }
    } else {
        zip.start_file(entry, options)?;
        let mut f = std::fs::File::open(path)?;
        std::io::copy(&mut f, zip)?;
    }
    Ok(())
}

fn make_zip(st: &AppState, names: &[String], prefix: &str) -> std::io::Result<PathBuf> {
    let out = st.temp_dir.join(format!("{}_{}.zip", prefix, Local::now().format("%Y%m%d_%H%M%S")));
    let file = std::fs::File::create(&out)?;
    let mut zip = zip::ZipWriter::new(file);
    let options = FileOptions::default()
        .compression_method(CompressionMethod::Deflated)
        .large_file(true);
    for name in names {
        if let Some(path) = resolve_existing(&st.share_dir, name) {
            add_to_zip(&mut zip, &path, name, options.clone())?;
        }
    }
    zip.finish()?;
    Ok(out)
}

async fn file_response(st: &AppState, name: &str, attachment: bool) -> Response {
    let path = match resolve_existing(&st.share_dir, name) {
        Some(p) => p,
        None => return StatusCode::NOT_FOUND.into_response(),
    };
    if path.is_dir() {
        let zip_path = match make_zip(st, &[name.to_string()], "folder") {
            Ok(p) => p,
            Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
        };
        return file_response_raw(&zip_path, true).await;
    }
    file_response_raw(&path, attachment).await
}

async fn file_response_raw(path: &FsPath, attachment: bool) -> Response {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return StatusCode::NOT_FOUND.into_response(),
    };
    let name = path.file_name().unwrap_or_default().to_string_lossy().into_owned();
    let mime = mime_of(&name);
    let mut builder = Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, HeaderValue::from_static(mime))
        .header(CONTENT_LENGTH, meta.len().to_string());
    if attachment {
        let ascii = name.chars().map(|c| if c.is_ascii_graphic() { c } else { '_' }).collect::<String>();
        let disposition = format!("attachment; filename=\"{}\"; filename*=UTF-8''{}", ascii, url_encode(&name));
        if let Ok(v) = HeaderValue::from_str(&disposition) {
            builder = builder.header(CONTENT_DISPOSITION, v);
        }
    }
    let file = match tokio::fs::File::open(path).await {
        Ok(f) => f,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let stream = ReaderStream::new(file);
    builder.body(Body::from_stream(stream)).unwrap()
}

async fn download_one(State(st): State<AppState>, Path(name): Path<String>) -> Response {
    file_response(&st, &name, true).await
}

async fn preview_one(State(st): State<AppState>, Path(name): Path<String>) -> Response {
    let mut resp = file_response(&st, &name, false).await;
    resp.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("no-store"));
    resp
}

async fn download_selected(State(st): State<AppState>, RawQuery(q): RawQuery) -> Response {
    // 不能用 Query<HashMap>：重复的 ?name=a&name=b 只会留下最后一个
    let names: Vec<String> = q
        .unwrap_or_default()
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .filter(|(k, _)| *k == "name")
        .filter_map(|(_, v)| safe_basename(&percent_decode(v)))
        .collect();
    if names.is_empty() {
        return (StatusCode::BAD_REQUEST, Json(json!({"success": false, "message": "未选择任何项目"}))).into_response();
    }
    match make_zip(&st, &names, "selected") {
        Ok(p) => file_response_raw(&p, true).await,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn download_all(State(st): State<AppState>) -> Response {
    let mut names = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&st.share_dir) {
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if resolve_existing(&st.share_dir, &name).is_some() {
                names.push(name);
            }
        }
    }
    if names.is_empty() {
        return (StatusCode::NOT_FOUND, Json(json!({"success": false, "message": "暂无可下载的文件"}))).into_response();
    }
    match make_zip(&st, &names, "files") {
        Ok(p) => file_response_raw(&p, true).await,
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

async fn delete_names(st: &AppState, names: &[String]) -> usize {
    let mut deleted = 0usize;
    for name in names {
        if let Some(path) = resolve_existing(&st.share_dir, name) {
            let ok = if path.is_dir() {
                tokio::fs::remove_dir_all(&path).await.is_ok()
            } else {
                tokio::fs::remove_file(&path).await.is_ok()
            };
            if ok {
                deleted += 1;
            }
        }
    }
    if deleted > 0 {
        st.hub.broadcast("{\"type\":\"files_changed\"}".to_string(), None).await;
    }
    deleted
}

async fn delete_selected(State(st): State<AppState>, Json(payload): Json<serde_json::Value>) -> Response {
    let names: Vec<String> = payload
        .get("names")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|x| x.as_str()).filter_map(safe_basename).collect())
        .unwrap_or_default();
    let n = delete_names(&st, &names).await;
    Json(json!({"success": n > 0, "deleted": n, "failed": [], "message": format!("成功删除 {} 个项目", n)})).into_response()
}

async fn delete_one(State(st): State<AppState>, Path(name): Path<String>) -> Response {
    let n = delete_names(&st, &[name]).await;
    if n > 0 {
        Json(json!({"success": true, "message": "删除成功"})).into_response()
    } else {
        (StatusCode::NOT_FOUND, Json(json!({"success": false, "message": "文件不存在"}))).into_response()
    }
}

async fn clear_download(State(st): State<AppState>) -> Response {
    let mut names = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&st.share_dir) {
        for e in entries.flatten() {
            names.push(e.file_name().to_string_lossy().into_owned());
        }
    }
    let n = delete_names(&st, &names).await;
    Json(json!({"success": true, "message": format!("已清空 {} 个项目", n)})).into_response()
}

// ---------------------------------------------------------------- WebSocket 群聊

async fn chat_ws(
    ws: WebSocketUpgrade,
    Query(params): Query<HashMap<String, String>>,
    State(st): State<AppState>,
) -> Response {
    let nick = params
        .get("nick")
        .map(|s| s.chars().take(20).collect::<String>())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "设备".to_string());
    ws.on_upgrade(move |socket| chat_socket(socket, st, nick))
}

async fn send_text(socket: &mut WebSocket, text: String) -> bool {
    socket.send(Message::Text(text)).await.is_ok()
}

async fn chat_socket(mut socket: WebSocket, st: AppState, nick: String) {
    let (tx, mut rx) = mpsc::unbounded_channel::<String>();
    let (id, history) = st.hub.join(nick.clone(), tx).await;
    let users = st.hub.users().await;
    let online = st.hub.online().await;

    if !send_text(
        &mut socket,
        json!({"type": "welcome", "user_id": id.to_string(), "nick": nick,
               "online_count": online, "users": users}).to_string(),
    ).await {
        st.hub.leave(id).await;
        return;
    }
    for h in history {
        if !send_text(&mut socket, h).await {
            st.hub.leave(id).await;
            return;
        }
    }

    let joined = json!({"type": "system", "message": format!("{} 加入了共享", nick),
                        "timestamp": now_iso(), "online_count": st.hub.online().await,
                        "users": st.hub.users().await}).to_string();
    st.hub.push_history(joined.clone()).await;
    st.hub.broadcast(joined, Some(id)).await;

    loop {
        tokio::select! {
            outgoing = rx.recv() => {
                match outgoing {
                    Some(text) => { if !send_text(&mut socket, text).await { break; } }
                    None => break,
                }
            }
            incoming = socket.recv() => {
                match incoming {
                    Some(Ok(Message::Text(text))) => {
                        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                            let kind = v.get("type").and_then(|x| x.as_str()).unwrap_or("");
                            if kind == "chat" || kind == "file_shared" {
                                let message = v.get("message").and_then(|x| x.as_str()).unwrap_or("").trim();
                                if !message.is_empty() {
                                    let msg = json!({"type": kind, "user_id": id.to_string(),
                                        "nick": nick, "message": message.chars().take(2000).collect::<String>(),
                                        "timestamp": now_iso()}).to_string();
                                    if kind == "chat" { st.hub.push_history(msg.clone()).await; }
                                    st.hub.broadcast(msg, Some(id)).await;
                                }
                            }
                        }
                    }
                    Some(Ok(Message::Ping(data))) => {
                        if socket.send(Message::Pong(data)).await.is_err() { break; }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    _ => {}
                }
            }
        }
    }

    st.hub.leave(id).await;
    let left = json!({"type": "system", "message": format!("{} 离开了共享", nick),
                      "timestamp": now_iso(), "online_count": st.hub.online().await,
                      "users": st.hub.users().await}).to_string();
    st.hub.push_history(left.clone()).await;
    st.hub.broadcast(left, None).await;
}

// ---------------------------------------------------------------- 启动

fn parse_args() -> (u16, PathBuf, bool) {
    let mut port = 5000u16;
    let mut dir = PathBuf::from("download");
    let mut no_gui = false;
    let args: Vec<String> = std::env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--port" | "-p" => {
                if let Some(v) = args.get(i + 1) {
                    port = v.parse().unwrap_or(5000);
                    i += 1;
                }
            }
            "--dir" | "-d" => {
                if let Some(v) = args.get(i + 1) {
                    dir = PathBuf::from(v);
                    i += 1;
                }
            }
            "--no-gui" => no_gui = true,
            "--help" | "-h" => {
                println!("文件共享中心 · PC 端（Rust）");
                println!("用法：file-share-pc [--port 5000] [--dir D:\\共享文件夹] [--no-gui]");
                println!("  --no-gui  只运行服务，不开图形窗口（适合后台/计划任务）");
                std::process::exit(0);
            }
            _ => {}
        }
        i += 1;
    }
    (port, dir, no_gui)
}

async fn run_server(
    port: u16,
    share_dir: PathBuf,
    temp_dir: PathBuf,
    hub: Arc<WsHub>,
) -> Result<(), String> {
    let state = AppState { share_dir, temp_dir, port, hub };
    let addr = SocketAddr::from(([0, 0, 0, 0], port));
    let cors = CorsLayer::new().allow_origin(Any).allow_methods(Any).allow_headers(Any);

    let app = Router::new()
        .route("/health", get(health))
        .route("/files", get(list_files))
        .route("/upload", post(upload))
        .route("/upload-folder", post(upload_folder))
        .route("/download-selected", get(download_selected))
        .route("/download-all", get(download_all))
        .route("/download/*name", get(download_one))
        .route("/preview/*name", get(preview_one))
        .route("/delete-selected", post(delete_selected))
        .route("/delete/*name", delete(delete_one))
        .route("/clear-download", post(clear_download))
        .route("/chat", get(chat_ws))
        .fallback(get(serve_asset))
        .with_state(state)
        .layer(cors);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .map_err(|e| format!("端口 {} 绑定失败：{}（试试 --port 5001）", port, e))?;
    axum::serve(listener, app).await.map_err(|e| e.to_string())
}

fn main() {
    let (port, raw_dir, no_gui) = parse_args();
    let share_dir = std::fs::canonicalize(&raw_dir).unwrap_or_else(|_| {
        std::fs::create_dir_all(&raw_dir).expect("无法创建共享目录");
        std::fs::canonicalize(&raw_dir).expect("无法定位共享目录")
    });
    let app_dir = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let temp_dir = app_dir.join("temp");
    let _ = std::fs::create_dir_all(&temp_dir);
    let _ = std::fs::create_dir_all(&share_dir);

    let hub = Arc::new(WsHub::new());
    let server_hub = hub.clone();
    let server_dir = share_dir.clone();
    let server_temp = temp_dir.clone();
    let (tx, rx) = std::sync::mpsc::channel::<Result<(), String>>();

    std::thread::spawn(move || {
        let rt = match tokio::runtime::Builder::new_multi_thread().enable_all().build() {
            Ok(rt) => rt,
            Err(e) => { let _ = tx.send(Err(e.to_string())); return; }
        };
        let result = rt.block_on(run_server(port, server_dir, server_temp, server_hub));
        let _ = tx.send(result);
    });

    if no_gui {
        // 纯后台模式：主线程挂住即可，窗口不显示
        loop {
            std::thread::sleep(std::time::Duration::from_secs(3600));
        }
    } else {
        launcher::run(port, lan_ip(), share_dir, hub, rx);
    }
}
