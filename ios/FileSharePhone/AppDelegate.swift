import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?
    let server = FileShareServer()

    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    static var shared: AppDelegate {
        UIApplication.shared.delegate as! AppDelegate
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // 尽早启动监听，保证 WKWebView 首次加载时 127.0.0.1:5000 已经可用
        server.start()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.backgroundColor = .systemBackground
        window.rootViewController = ViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        endBackgroundTask()
        server.start()
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        endBackgroundTask()
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // iOS 系统限制：App 进入后台后很快会被挂起，所有 socket 随之停止收发数据。
        // beginBackgroundTask 只能额外争取很短的一段时间（通常约 30 秒，且由系统决定），
        // 无法让 HTTP/WebSocket 服务常驻。**必须保持 App 在前台才能当主机**。
        // 这里尽力延长，让正在进行的上传/下载有机会收尾，仅此而已。
        backgroundTask = application.beginBackgroundTask(withName: "FileShareServer") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func applicationWillTerminate(_ application: UIApplication) {
        server.stop()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}
