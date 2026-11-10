# 文件共享中心 · PC 端（Rust 版）

一个**单文件 exe** 的 PC 服务端。移动端前端通过 `rust-embed` 编译进二进制，运行时不需要 Python、Node、.NET 或任何运行时库，只要一个 exe + 一个共享文件夹。

**双击运行打开的是图形启动器窗口**（egui 原生界面，不是黑窗）：显示服务运行状态、本机/局域网地址、共享项目数与在线设备数，并提供「复制邀请链接 / 打开网页 / 共享文件夹」按钮。HTTP 服务跑在后台线程，关闭窗口即停止服务。加 `--no-gui` 可转为无窗口的纯后台模式。窗口界面优先加载系统黑体（`C:/Windows/Fonts/simhei.ttf`），缺失时回退到等线或其他中文字体。

## 为什么单独做 Rust 版

| | Python 版 | Rust 版 |
|---|---|---|
| 运行依赖 | Python 3.7+ 与四个 pip 包 | 无 |
| 分发 | 脚本 / PyInstaller 打包 | 单个 exe，约几 MB |
| 内存/并发 | GIL + 线程 | Tokio 异步，低开销 |
| 前端 | 外部 `static/` 目录 | 编译期嵌入 exe |

两者 API 完全一致，可以**混用**：Rust 版当主机时，Python 版、安卓 App、iOS App、手机浏览器都能连进来；反之亦然。

## 编译

前置：Rust 工具链（[rustup](https://rustup.rs/)）。本机若用 `--no-modify-path` 安装，脚本会自动补上 `~/.cargo/bin`。

```bash
# Windows：双击 build.bat，或 Git Bash 执行
bash build.sh

# 通用
cargo build --release
```

产物在 `target/release/file-share-pc.exe`，`build.sh` 会另外复制一份到本目录根目录。

> 若链接阶段报 `link.exe not found`：本机没有 Visual Studio Build Tools。已有的 MinGW 可用，装 GNU 工具链即可：
> `rustup toolchain install stable-x86_64-pc-windows-gnu && rustup default stable-x86_64-pc-windows-gnu`

## 运行

```bash
file-share-pc.exe                                  # 图形启动器；默认 5000 端口，共享目录 ./download
file-share-pc.exe --port 5001 --dir D:\共享文件夹
file-share-pc.exe --no-gui                         # 纯后台，不弹窗口（计划任务用）
file-share-pc.exe --help
```

双击 `start.bat` 或直接双击 exe 都可以。**发布版用 `windows_subsystem = "windows"` 编译，运行时不会弹出黑色控制台窗口**；服务状态、地址都显示在图形窗口里。

窗口里会显示 `http://127.0.0.1:5000` 与 `http://192.168.1.8:5000`。**手机连同一个 WiFi 打开「局域网访问」地址即可。** 首次弹出 Windows 防火墙提示时勾选「专用网络」允许访问。若端口被占用，窗口会以红色文字提示原因（可改用 `--port 5001`）。

## 功能（与 server.py 对照）

| 能力 | 实现 |
|---|---|
| 静态前端 | index.html / app.js / style.css / sw.js / 两个离线二维码库 / 图标，全部嵌入 exe |
| 心跳 | `GET /health`（含局域网 IP、端口、在线数、共享项目数） |
| 文件列表 | `GET /files`，文件夹优先、按修改时间倒序，含大小与文件数 |
| 上传 | `POST /upload`、`POST /upload-folder`，**流式写盘**，大文件不整块进内存，重名自动加 `(1)` |
| 下载 / 预览 | `GET /download/<name>`、`GET /preview/<name>`，文件夹自动打 ZIP；大文件流式输出 |
| 批量 | `GET /download-selected?name=a&name=b`（逐个 name 解析，不丢多选）、`GET /download-all` |
| 删除 | `POST /delete-selected`、`DELETE /delete/<name>`、`POST /clear-download` |
| 群聊 | `GET /chat?nick=` WebSocket：欢迎、在线名单、加入/离开、100 条历史、分享通知、`files_changed` 实时刷新 |
| CORS | 全部响应 `Access-Control-Allow-Origin: *`，OPTIONS 预检自动处理 |
| 安全 | `safe_basename` + `resolve_existing`/`resolve_new` 双重校验，拒绝 `../`、绝对路径、控制字符 |

## 目录结构

```
pc-rust/
├── Cargo.toml
├── src/main.rs          全部服务端逻辑（约 700 行）
├── static/              pc-rust 版前端副本（编译期嵌入；改前端后需重新编译）
├── build.sh / build.bat
├── start.bat
├── target/release/       cargo 构建产物
└── file-share-pc.exe     构建后复制到根目录的成品
```

## 已知限制

- **无登录鉴权**：仅限可信局域网，不要把端口映射到公网。
- ZIP 使用 store/deflate 模式且未启用 Zip64，单文件超过约 4GB 会被跳过。
- 临时文件写在 `./temp/`，程序退出不会自动清理全部历史打包文件。
- 共享目录默认 `./download`，卸载/删除目录前请先导出重要文件。
- 前端更新后需要重新 `cargo build --release`（因为资源是编译期嵌入的）。
