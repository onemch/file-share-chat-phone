# 文件共享中心 · 手机版（iOS 原生 App）

这个目录是一个**完整、可直接在 macOS 上用 Xcode 打开并 Archive 的 iOS App 工程**。

它在 iPhone 里内嵌了一个与 `server.py`（Flask 版）行为等价的 **HTTP + WebSocket 服务端**，
让 iPhone 自己可以当「主机」；同时用 `WKWebView` 加载同一套前端页面，
所以也能在「连接」页填其他主机的 IP 当客户端加入别人的共享空间。

- 语言：Swift 5
- 网络：仅用系统框架 `Network.framework`（`NWListener` / `NWConnection`）
- 依赖：**零第三方依赖**，没有 CocoaPods / Swift Package / 任何 vendored 代码
- 最低系统：iOS 15.0
- Bundle ID：`com.fileshare.phone`
- 端口：5000，监听所有网卡
- 共享目录：`Documents/SharedFiles`（已开启 iTunes/文件 App 共享，可在「文件」App 里直接看到）

> ⚠️ 本工程是在 Windows 机器上编写的，**没有在 macOS 上编译 / 签名 / 真机运行验证过**。
> 请按下面的步骤在 Mac 上打开并编译；若 Xcode 报出具体编译错误，按报错行修正即可
> （都是局部语法问题，不涉及架构）。详见文末「已知残留风险」。

---

## 一、目录结构

```
ios/
├── README.md                      本文档
├── exportOptions.plist            IPA 导出配置（默认 development，免费 Apple ID 可用）
├── build-ipa.sh                    macOS 一键 Archive + 导出 IPA（自动注入 Team ID）
├── FileSharePhone.xcodeproj/
│   ├── project.pbxproj            手写、语法完整的工程文件（单 App target）
│   └── xcshareddata/xcschemes/
│       └── FileSharePhone.xcscheme
└── FileSharePhone/
    ├── AppDelegate.swift          前台启动服务 / 后台 beginBackgroundTask
    ├── ViewController.swift      WKWebView + 状态栏 + 复制地址 + 原生选文件上传 + 下载分享
    ├── Info.plist                ATS 明文 HTTP、本地网络权限、后台说明等
    ├── www/                      前端静态资源（从 static/ 原样复制，作为 folder reference 打进 bundle）
    │   ├── index.html
    │   ├── app.js
    │   ├── style.css
    │   ├── manifest.webmanifest
    │   ├── sw.js
    │   ├── icon-192.png
    │   ├── icon-512.png
    │   └── apple-touch-icon.png
    └── Server/
        ├── HTTPServer.swift       NWListener、连接状态机、HTTP 收发、WS 升级、文件流式直出
        ├── HTTPTypes.swift        HTTPRequest / HTTPResponse / 百分号解码 / MIME / Content-Disposition
        ├── Router.swift          全部 HTTP API 路由与静态资源映射
        ├── MultipartParser.swift 流式 multipart/form-data 解析（文件不整块进内存）
        ├── FileStore.swift       共享目录、safe basename、防穿越、列表、重命名、ZIP 打包
        ├── ChatHub.swift         线程安全客户端集合、历史回放、广播、files_changed
        ├── WebSocket.swift       握手 SHA1、帧解析（mask / 7-16-64 位长度 / 分片 / ping-pong-close）
        ├── ZipWriter.swift        纯手写最小 ZIP（store 模式 + UTF-8 文件名标志位）
        └── NetworkInfo.swift      取本机局域网 IPv4（getifaddrs，优先 WiFi en0）
```

`www/` 在 `project.pbxproj` 中是 **folder reference（蓝色文件夹）**，会连目录结构一起复制进
bundle；运行时 `Bundle.main.bundleURL/www/` 即静态资源根目录（代码里还有扁平化兜底查找）。

---

## 二、在 Mac 上打开、签名、Archive、导出 IPA（完整步骤）

### 1. 打开工程

1. 把整个 `ios/` 目录拷到 Mac。
2. 用 **Xcode 14 或更新版本**打开 `FileSharePhone.xcodeproj`（双击即可，或 Xcode → File → Open）。
3. 左侧导航里应能看到 `FileSharePhone` group 下的 11 个 `.swift`、`Info.plist` 和蓝色的 `www` 文件夹。
4. 选中工程根节点 → `FileSharePhone` target → `General` 页，确认：
   - Deployment Target：`iOS 15.0`
   - Bundle Identifier：`com.fileshare.phone`
   - 如需改 Bundle ID，请同时改 `Info.plist` 里的 `CFBundleIdentifier` 与 `exportOptions.plist`。

### 2. 选 Team 签名（必做，否则无法装真机）

1. Xcode → `Settings…`（`Preferences`）→ `Accounts`，用 Apple ID 登录。
   - **免费 Apple ID**：直接选 `Personal Team` 即可，不需要付费。
   - **付费 Apple Developer Program**：选对应的 Team。
2. 回到 target → `Signing & Capabilities`，勾选 `Automatically manage signing`，
   在 `Team` 下拉里选你的 Team。
3. Xcode 会自动生成 `Apple Development` 证书与 provisioning profile。
   若报 `Signing for "FileSharePhone" requires a development team`，说明上一步没选。
4. `Info.plist` 里已声明 `NSLocalNetworkUsageDescription`（局域网权限）与
   `NSAppTransportSecurity`（明文 HTTP），首次启动会弹「本地网络」授权，请点**允许**，
   否则其他设备无法连上这台 iPhone。

### 3. 选真机并跑一次

1. 用数据线接上 iPhone，解锁并信任此电脑。
2. 顶部设备下拉选这台**真机**（不要选 Simulator —— 模拟器也能编译运行，但「局域网 IP」对
   外部设备没有意义，验证共享请用真机）。
3. `⌘R` 运行。App 顶部紫色状态栏显示 `本机服务 · 运行中` 与 `http://192.168.x.x:5000`。
4. 点「复制」把局域网地址复制到剪贴板，发给同一 WiFi 下的其他手机，用浏览器打开即可加入。

### 4. Archive 并导出 IPA

1. 顶部设备选择 **`Any iOS Device (arm64)`**（Generic iOS Device），否则 `Archive` 是灰的。
2. 菜单 `Product` → `Archive`。等待编译与归档完成，会自动打开 `Organizer`。
3. 在 `Organizer` → `Archives` 选中刚生成的 Archive，点 **`Distribute App`**。
4. 选择分发方式：
   - **`Development`**：装到已登记到 Team 的开发设备，最简单。
   - **`Ad Hoc`**：装到在 Developer 后台登记过 UDID 的设备，可发给别人装（推荐自测用）。
   - `App Store Connect` 不适用于这种自用工具，可忽略。
5. 一路 Next，签名方式选 `Automatic`，Xcode 会生成 `.ipa`。
   最后一步选 `Export`，把导出的文件夹保存好，里面就有 `FileSharePhone.ipa`。
6. 安装 IPA 的方式：
   - Xcode → `Window` → `Devices and Simulators` → 选中设备 → `+` 选 IPA；
   - 或 Apple Configurator 2 / `ideviceinstaller` / 企业分发 / 第三方签名工具（如 AltStore、Sideloadly）。

#### 命令行方式（可选）

```bash
# 归档
xcodebuild -project FileSharePhone.xcodeproj \
           -scheme FileSharePhone \
           -configuration Release \
           -archivePath ./build/FileSharePhone.xcarchive \
           CODE_SIGN_STYLE=Automatic \
           DEVELOPMENT_TEAM=YOUR_TEAM_ID \
           archive

# 导出（把上面 DEVELOPMENT_TEAM 的 YOUR_TEAM_ID 换成真实 Team ID 即可；
#       development + 自动签名下 exportOptions.plist 无需改动。
#       改用 Ad Hoc 时才按该文件注释补 provisioningProfiles）
xcodebuild -exportArchive \
           -archivePath ./build/FileSharePhone.xcarchive \
           -exportOptionsPlist ./exportOptions.plist \
           -exportPath ./build/ipa
```

#### 一键脚本（推荐）

```bash
TEAM_ID=ABCDE12345 bash build-ipa.sh
```

脚本依次执行 `xcodebuild archive` → 复制 `exportOptions.plist` 到 `build/` →
用 `PlistBuddy` 把你的 `TEAM_ID` 注入副本 → `xcodebuild -exportArchive`。
**不需要手动修改 plist 里的任何占位符**：模板 `exportOptions.plist` 保持
`method=development`（免费 Apple ID 可用，且不含写死的 teamID），签名信息由
archive 阶段的 `DEVELOPMENT_TEAM` 和脚本注入的副本共同提供。

想改用 Ad Hoc 时，按 `exportOptions.plist` 里的注释修改 `method` 并补
`provisioningProfiles`，脚本仍会自动注入 Team ID。产物：`build/ipa/FileSharePhone.ipa`。

---

## 三、签名有效期（重要）

| 账号类型 | 签名有效期 | 到期后 |
| --- | --- | --- |
| **免费 Apple ID（Personal Team）** | **7 天** | App 打不开，必须**每 7 天重新用 Xcode 装一次 / 重签一次** |
| **付费 Apple Developer Program（个人/公司，¥688/年）** | **1 年**（profile 随证书） | 每年续费后重新签名即可 |
| Ad Hoc（付费账号） | 最长 1 年，且设备 UDID 必须已登记 | 到期或换设备需重新导出 |
| App Store / TestFlight | 不适用本工具 | — |

免费账号还有额外限制：最多登记少量设备、App ID 数量有限、不能用某些 Capability。
本工程只用最基础的签名，免费账号完全够用，代价就是 7 天重签。

---

## 四、iOS 当「主机」的后台限制（务必读，别误以为能常驻）

这是 **iOS 系统限制，不是本工程的 bug**：

- App 一进入后台，系统很快（通常几秒到几十秒）就会**挂起进程**，所有 socket 停止收发数据。
  `NWListener` 虽然在对象层面还「活着」，但外部设备已经连不上、已连的 WebSocket 也会断。
- `AppDelegate` 里调用了 `beginBackgroundTask(withName:)`，只能**再争取很短一段执行时间**
  （系统给的额度不固定，通常约 30 秒，且随时可能被系统收回），目的是让正在进行的
  上传 / 下载有机会收尾，**并不能让 HTTP 服务常驻后台**。
- `Info.plist` 里声明了 `UIBackgroundModes = fetch` 也只是配合说明，
  **iOS 没有给普通第三方 App 提供「后台常驻 TCP 监听」的合法模式**。
- 结论：**要让这台 iPhone 当主机，必须保持 App 在前台、屏幕解锁**。
  锁屏、切到别的 App、来电、息屏都会让服务很快不可用。
  想要稳定长期当主机，请用电脑跑 `server.py`，或安卓 Termux 跑 `termux-start.sh`，
  iPhone 只当客户端（在「连接」页填对方地址）才是舒服的用法。

回到前台时 `applicationDidBecomeActive` 会再次调用 `server.start()`；
如果之前监听失败（例如端口被占用），会在通知里重试启动。

---

## 四·补：加入其他主机的几种方式

「连接」页与网页版 / 安卓 App 完全一致，四种方式任选：

| 方式 | 说明 |
|---|---|
| 扫码连接 | 局域网 HTTP 下用「拍照 / 相册选图」识别（WKWebView 不直接授权摄像头）；HTTPS 或安全上下文可用实时摄像头 |
| 剪贴板 | 点「剪贴板」读系统剪贴板自动识别；也可在输入框粘贴、或在页面任意处粘贴即连 |
| 附近主机 | 自动探测同网段 `1~254` 的 `/health`，列出可连接的主机与在线人数 |
| 手动输入 | 支持完整 URL、纯 IP、`IP:端口` 三种写法 |

本机邀请二维码由前端 `qrcode.min.js` 在 canvas 上生成（不依赖服务端 `/qr.png`），扫码解码用 `jsqr.min.js`；两个库都随 `www` 打进 bundle，**完全离线可用**。顶部连接灯可点击直达「连接」页。

## 五、网络与防火墙要求

1. **同一 WiFi / 同一局域网**：其他设备必须和这台 iPhone 在同一个二层网络，
   能直接访问 `http://<iPhone 的 LAN IP>:5000`。蜂窝网络、不同 VLAN、访客网络隔离都不行。
2. **路由器「AP 隔离 / 客户端隔离」必须关闭**，否则手机之间互相访问不到。
3. **本机没有防火墙需要配置**（iOS 无入站防火墙开关）；但要确认 iPhone 连的是 WiFi 而不是
   只用蜂窝——`NetworkInfo.swift` 优先取 `en0`（WiFi）的私有 IPv4，
   若只连蜂窝会取到 `10.x` 这类地址，外部设备通常无法直连。
4. **端口 5000**：若被占用（例如同一网络里另一台设备也在跑），服务会启动失败，
   顶部状态栏会显示失败原因。改端口请同时改 `HTTPServer.swift` 的 `port`、
   `loopbackAddress` 与 `ViewController.swift` 里加载的地址。
5. 电脑/手机上的**防火墙、公司网络策略、VPN** 都可能拦截 5000 端口，家用 WiFi 一般没问题。
6. iOS 14+ 首次访问局域网会弹权限框，`NSLocalNetworkUsageDescription` 已配置，请点允许。

---

## 六、安全提醒：无鉴权，不要暴露公网

- 本服务和 `server.py` 一样**完全没有鉴权**：任何能访问到该地址的人都能
  上传、下载、删除共享目录里的全部文件，并读取群聊消息。
- **只在可信的局域网（自己家 / 可信办公室 WiFi）里使用**。
- **不要**做端口映射、不要放到公网、不要挂到云服务器、不要在开放 WiFi（咖啡厅、机场、
  酒店、校园网）里当主机。
- 用完建议直接杀掉 App（或保持前台时手动清空共享目录）。

---

## 七、iOS 端实现的服务能力清单（与 server.py 对照）

### HTTP 静态资源（前端会请求这些根路径，服务端已正确映射）
- `GET /` → `www/index.html`，`text/html; charset=utf-8`，`Cache-Control: no-cache`
- `GET /static/<文件名>` → `www/<文件名>`，仅允许 `[A-Za-z0-9_.-]+`，`.` 开头一律 404
  （前端用到 `/static/style.css`、`/static/app.js`、`/static/qrcode.min.js`、`/static/jsqr.min.js`）
- `GET /manifest.webmanifest`、`/sw.js`、`/icon-192.png`、`/icon-512.png`、
  `/apple-touch-icon.png`、`/favicon.ico` → `www/` 对应文件；
  `favicon.ico` 回退到 `icon-192.png`；`sw.js` 额外带 `Service-Worker-Allowed: /`
- `GET /qr.png` → **404**（邀请二维码已改为前端用 `qrcode.min.js` 在 canvas 上生成，
  不依赖服务端；扫码用 `jsqr.min.js`，局域网 HTTP 下走「拍照 / 相册选图」识别）
- 所有响应带 `Access-Control-Allow-Origin: *`；`OPTIONS` 预检返回 200 并带
  `Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS` 与 `Access-Control-Allow-Headers`

### HTTP API
| 路由 | 行为 |
| --- | --- |
| `GET /health` | `{ok, app, version, time, lan_ip, port, online, items}` |
| `GET /files` | 文件/文件夹列表，文件夹优先、modified 倒序；文件夹含 `file_count` |
| `POST /upload` | multipart 字段 `file`/`files[]`，可多个，重名自动加 `(1)` |
| `POST /upload-folder` | multipart 字段 `files[]` + `folder_name`，按相对路径保存，**严格拒绝 `..` 穿越** |
| `GET /download/<name>` | 文件直出（带 `Content-Disposition: attachment`），文件夹打 ZIP |
| `GET /preview/<name>` | 文件内联预览（`inline` + `no-store`），供图片/视频/PDF 使用 |
| `GET /download-selected?name=a&name=b` | 选中项打 ZIP |
| `GET /download-all` | 全部打 ZIP |
| `POST /delete-selected` | JSON `{"names":[...]}` 批量删除 |
| `DELETE /delete/<name>` | 删除单个 |
| `POST /clear-download` | 清空共享目录 |

### WebSocket `/chat?nick=xxx`
- 自己实现握手：`Sec-WebSocket-Key` + GUID → `Insecure.SHA1` → Base64（CryptoKit，系统框架）
- 帧解析：FIN/opcode、7 / 16 / 64 位长度、客户端 mask、分片续帧、ping→pong、close
- 服务端发文本帧不 mask；`NSLock` 保护客户端集合，广播线程安全
- `welcome`（`user_id` / `nick` / `online_count` / `users`）
- `chat` / `file_shared` 广播**不回发发送者**；`system` 加入/离开广播
- 最近 100 条历史**只回放 `chat` / `file_shared`，不回放 `system`**
- 任意上传 / 删除成功后广播 `{"type":"files_changed"}`，所有客户端立即刷新列表

### 文件与 ZIP
- 共享目录 `Documents/SharedFiles`；所有外部名称走
  `safe_basename` + `resolve_within` 等价实现，**防 `../`、绝对路径、`C:\`、控制字符穿越**
- multipart **流式解析**：每个文件 part 直接写入临时文件，再移动到共享目录，
  大文件不会整块读进内存
- 文件响应 64KB 分块流式直出，不整块读入内存
- ZIP 为**纯手写最小实现**：local file header + central directory + EOCD，
  store 模式、CRC32、UTF-8 文件名标志位 `0x0800`、DOS 时间戳；
  macOS「归档实用工具」与 Windows 资源管理器均可解压中文文件名

### App 层
- `AppDelegate`：进入前台启动服务，进入后台 `beginBackgroundTask` 尽力延长（见第四节）
- `ViewController`：`WKWebView` 全屏、允许 JS / DOM storage / 明文 HTTP（Info.plist ATS），
  加载 `http://127.0.0.1:5000/`；`WKNavigationDelegate` 实现
- 顶部紫色状态栏显示服务地址与运行状态，「复制」按钮复制局域网地址
- 文件选择：WKWebView 在 iOS 上支持 `<input type="file">`，**但不支持 `webkitdirectory`
  （选整个文件夹）**。因此额外提供顶部「上传」按钮，用 `UIDocumentPickerViewController`
  选多个文件后由原生代码组 multipart 上传到本机 `/upload`；
  同时注入 `window.FileShareNative.pickFiles()`（`WKScriptMessageHandler` 桥接）备用
- 下载：`decidePolicyFor navigationAction` / `decidePolicyFor navigationResponse`
  拦截 `Content-Disposition: attachment` 与 `/download*` 链接，取消 WebView 内部导航，
  改用 `URLSession` 下载到 `Documents/Downloads` 并弹 `UIActivityViewController` 系统分享面板
  （可「存储到文件」或发给其他 App）

---

## 八、已知残留风险 / 限制

1. **未编译验证**：Windows 上无 Xcode / Swift 工具链，工程、pbxproj、Swift 源码均按
   API 签名手写。已在本地做过 plist / XML / pbxproj 括号与 ID 引用完整性校验，
   但**真实编译、签名、真机运行未验证**。首次在 Xcode 打开若报错，通常是某个
   系统 API 的 Swift 名字在不同 Xcode 版本略有差异（例如 `NWEndpoint.Port(rawValue:)`、
   `FileHandle.readData(ofLength:)` 的弃用告警），按报错行微调即可。
2. `FileHandle.readData(ofLength:)` / `write(_:)` 在较新 SDK 里是 deprecated，
   会出**警告但不会报错**；如介意可替换为 `read(upToCount:)` / `write(contentsOf:)`。
3. `pbxproj` 的 `objectVersion = 50`（Xcode 10 格式），新版 Xcode 能直接读取并自动升级；
   若 Xcode 提示升级工程，同意即可。
4. `DEVELOPMENT_TEAM` 没有写死，必须在 Xcode 里手动选 Team（第二节）。
5. **ZIP 不支持 Zip64**：单个文件 ≥ 4GB 会被跳过（`ZipWriter.addFile` 里有保护）；
   store 模式不压缩，压缩包体积接近原文件之和，属预期行为。
6. **IPv6**：`NWListener(using:on:)` 默认双栈；`NetworkInfo.swift` 取的是 IPv4 LAN 地址，
   纯 IPv6 局域网下显示的地址可能不可用（家用 WiFi 基本都是 IPv4）。
7. **不支持 HTTPS / WSS**：与 `server.py` 一致，全部明文 HTTP（ATS 已放行）。
8. **端口固定 5000**：不提供运行时改端口的 UI。
9. **文件夹上传**：前端 `webkitdirectory` 在 WKWebView 里不可用；
   原生「上传」按钮只能选文件（可多选），要上传整个文件夹请在电脑端 / 安卓端操作，
   或把文件夹内容多选后上传（不会保留目录层级）。服务端 `/upload-folder` 本身是完整实现的。
10. **Service Worker**：`http://127.0.0.1` 属于安全上下文可注册；若连的是别的主机
    `http://192.168.x.x` 则不是安全上下文，`sw.js` 注册会失败，但前端已 `.catch()` 忽略，
    不影响使用。
11. **后台**：见第四节，切后台服务很快不可用，这是系统限制。
12. **AppIcon 已接入**：`FileSharePhone/Assets.xcassets/AppIcon.appiconset/` 里有
    `Icon-1024.png`（与 PWA 图标同一套设计）和 `Contents.json`，`project.pbxproj` 已把它
    加进 Resources 并在 Debug/Release 都设置了
    `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`。仍没有 LaunchScreen.storyboard
    （`Info.plist` 用空的 `UILaunchScreen`），Archive 时可能给出「缺少启动图」的
    **警告（不是错误）**，不影响 Ad Hoc / Development 导出。
