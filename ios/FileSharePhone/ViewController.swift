import UIKit
import WebKit
import UniformTypeIdentifiers

final class ViewController: UIViewController {

    private var webView: WKWebView!
    private let statusBar = UIView()
    private let statusLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let uploadButton = UIButton(type: .system)

    private var currentAddress: String = "http://127.0.0.1:5000"
    private var initialLoadDone = false
    private var loadRetry = 0

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupStatusBar()
        setupWebView()
        updateStatusFromServer()
        loadLocalHost()

        NotificationCenter.default.addObserver(
            self, selector: #selector(statusDidChange(_:)),
            name: .fileShareServerStatus, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "nativeUpload")
    }

    // MARK: - 顶部状态栏

    private func setupStatusBar() {
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.backgroundColor = UIColor(red: 0.42, green: 0.36, blue: 0.91, alpha: 1.0)
        view.addSubview(statusBar)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.numberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusBar.addSubview(statusLabel)

        uploadButton.translatesAutoresizingMaskIntoConstraints = false
        uploadButton.setTitle("上传", for: .normal)
        uploadButton.setTitleColor(.white, for: .normal)
        uploadButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        uploadButton.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        uploadButton.layer.cornerRadius = 8
        uploadButton.addTarget(self, action: #selector(pickFiles), for: .touchUpInside)
        statusBar.addSubview(uploadButton)

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.setTitle("复制", for: .normal)
        copyButton.setTitleColor(.white, for: .normal)
        copyButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .semibold)
        copyButton.backgroundColor = UIColor.white.withAlphaComponent(0.22)
        copyButton.layer.cornerRadius = 8
        copyButton.addTarget(self, action: #selector(copyAddress), for: .touchUpInside)
        statusBar.addSubview(copyButton)

        NSLayoutConstraint.activate([
            statusBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 58),

            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: uploadButton.leadingAnchor, constant: -8),

            uploadButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            uploadButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            uploadButton.widthAnchor.constraint(equalToConstant: 52),
            uploadButton.heightAnchor.constraint(equalToConstant: 32),

            copyButton.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -12),
            copyButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 52),
            copyButton.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func renderStatus(running: Bool, note: String) {
        let first = running ? "本机服务 · 运行中" : "本机服务 · 未运行"
        let second = note.isEmpty ? currentAddress : note
        statusLabel.text = first + "\n" + second
    }

    private func updateStatusFromServer() {
        let s = AppDelegate.shared.server
        currentAddress = s.displayAddress
        renderStatus(running: s.isRunning, note: s.statusNote)
    }

    @objc private func statusDidChange(_ note: Notification) {
        let info = note.userInfo ?? [:]
        let running = (info["running"] as? Bool) ?? false
        if let addr = info["address"] as? String { currentAddress = addr }
        let noteText = (info["note"] as? String) ?? ""
        renderStatus(running: running, note: noteText)
        if running && !initialLoadDone { loadLocalHost() }
    }

    @objc private func copyAddress() {
        UIPasteboard.general.string = currentAddress
        showToast("已复制：\(currentAddress)")
    }

    // MARK: - WKWebView

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 允许 localStorage / DOM storage；明文 HTTP 由 Info.plist 的 ATS 配置放行
        config.websiteDataStore = .default()

        let controller = WKUserContentController()
        controller.add(self, name: "nativeUpload")
        // 注入一个最小桥接：前端 app.js 无法修改，但未来可通过
        // window.FileShareNative.pickFiles() 唤起原生文件选择器。
        let bridge = WKUserScript(
            source: "window.FileShareNative = window.FileShareNative || {};"
                + "window.FileShareNative.pickFiles = function(){"
                + "window.webkit.messageHandlers.nativeUpload.postMessage({type:'pickFiles'});"
                + "};",
            injectionTime: .atDocumentStart, forMainFrameOnly: true)
        controller.addUserScript(bridge)
        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.backgroundColor = .systemBackground
        view.addSubview(wv)
        webView = wv

        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: statusBar.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func loadLocalHost() {
        let address = AppDelegate.shared.server.loopbackAddress
        guard let url = URL(string: address) else { return }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        webView.load(request)
    }

    // MARK: - 原生文件选择上传

    @objc private func pickFiles() {
        // WKWebView 在 iOS 上支持 <input type="file">，但不支持 webkitdirectory（选文件夹）。
        // 因此额外提供这个原生按钮，用 UIDocumentPickerViewController 选文件后自行组 multipart 上传。
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func uploadFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let boundary = "----FileSharePhone" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let bodyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("fsc_upload_\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: bodyFile.path, contents: nil),
              let out = try? FileHandle(forWritingTo: bodyFile) else {
            showToast("无法创建上传临时文件")
            return
        }

        for u in urls {
            let name = escapeHeaderValue(u.lastPathComponent)
            let header = "--\(boundary)\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\n"
                + "Content-Type: application/octet-stream\r\n\r\n"
            try? out.write(contentsOf: Data(header.utf8))
            if let input = try? FileHandle(forReadingFrom: u) {
                while true {
                    let chunk = input.readData(ofLength: 64 * 1024)
                    if chunk.isEmpty { break }
                    try? out.write(contentsOf: chunk)
                }
                try? input.close()
            }
            try? out.write(contentsOf: Data("\r\n".utf8))
        }
        try? out.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
        try? out.close()

        guard let url = URL(string: AppDelegate.shared.server.loopbackAddress + "upload") else {
            try? FileManager.default.removeItem(at: bodyFile)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let task = URLSession.shared.uploadTask(with: request, fromFile: bodyFile) {
            [weak self] data, response, error in
            try? FileManager.default.removeItem(at: bodyFile)
            DispatchQueue.main.async {
                if let error = error {
                    self?.showToast("上传失败：\(error.localizedDescription)")
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                var ok = (200..<300).contains(code)
                if let data = data,
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    ok = ok && ((obj["success"] as? Bool) ?? false)
                }
                self?.showToast(ok ? "上传成功，已加入共享空间" : "上传失败（HTTP \(code)）")
            }
        }
        task.resume()
        showToast("正在上传 \(urls.count) 个文件…")
    }

    private func escapeHeaderValue(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
    }

    // MARK: - 下载拦截

    private func isDownloadURL(_ url: URL) -> Bool {
        let p = url.path
        return p.hasPrefix("/download/") || p == "/download-selected" || p == "/download-all"
    }

    private func startNativeDownload(_ url: URL) {
        showToast("开始下载…")
        let task = URLSession.shared.downloadTask(with: url) { [weak self] location, response, error in
            guard let self = self else { return }
            guard let location = location, error == nil else {
                DispatchQueue.main.async { self.showToast("下载失败") }
                return
            }
            let fromPath: String? = url.path.hasPrefix("/download/")
                ? url.lastPathComponent.removingPercentEncoding : nil
            let name = fromPath ?? (response?.suggestedFilename ?? "download")
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var dest = dir.appendingPathComponent((name as NSString).lastPathComponent)
            if FileManager.default.fileExists(atPath: dest.path) {
                let stem = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                dest = dir.appendingPathComponent(
                    stem + "-\(Int(Date().timeIntervalSince1970))" + (ext.isEmpty ? "" : "." + ext))
            }
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: location, to: dest)
                DispatchQueue.main.async { self.presentShare(for: dest) }
            } catch {
                DispatchQueue.main.async { self.showToast("保存失败") }
            }
        }
        task.resume()
    }

    private func presentShare(for url: URL) {
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = view
        vc.popoverPresentationController?.sourceRect =
            CGRect(x: view.bounds.midX, y: view.bounds.maxY - 100, width: 1, height: 1)
        present(vc, animated: true)
    }

    // MARK: - 轻提示

    private func showToast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        label.font = .systemFont(ofSize: 13)
        label.textAlignment = .center
        label.numberOfLines = 3
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -90),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            label.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
        UIView.animate(withDuration: 0.3, delay: 1.8, options: [], animations: {
            label.alpha = 0
        }, completion: { _ in
            label.removeFromSuperview()
        })
    }
}

// MARK: - WKNavigationDelegate

extension ViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // 下载链接：取消 WebView 内部导航，改用 URLSession 取回文件后弹系统分享面板
        if isDownloadURL(url) {
            decisionHandler(.cancel)
            startNativeDownload(url)
            return
        }
        if #available(iOS 14.5, *), navigationAction.shouldPerformDownload {
            decisionHandler(.cancel)
            startNativeDownload(url)
            return
        }
        if url.host == "127.0.0.1" || url.host == "localhost" {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "http" || url.scheme == "https" {
            // 其他主机/外部链接交给系统浏览器
            decisionHandler(.cancel)
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            return
        }
        decisionHandler(.allow)
    }

    /// 兜底：即便导航动作阶段未拦截（例如 <a download> 直接被 WebKit 视为下载），
    /// 在收到带 `Content-Disposition: attachment` 的响应时仍接管到系统下载/分享。
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().contains("attachment"),
           let url = navigationResponse.response.url {
            decisionHandler(.cancel)
            startNativeDownload(url)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        initialLoadDone = true
        loadRetry = 0
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        guard !initialLoadDone, loadRetry < 10 else { return }
        loadRetry += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self, !self.initialLoadDone else { return }
            self.loadLocalHost()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // 忽略子资源加载失败（例如 /qr.png 返回 404）
    }
}

// MARK: - WKScriptMessageHandler

extension ViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "nativeUpload",
              let body = message.body as? [String: Any],
              (body["type"] as? String) == "pickFiles" else { return }
        pickFiles()
    }
}

// MARK: - UIDocumentPickerDelegate

extension ViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for u in accessed { u.stopAccessingSecurityScopedResource() } }
        uploadFiles(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        // 用户取消
    }
}
