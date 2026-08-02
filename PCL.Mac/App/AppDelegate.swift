//
//  AppDelegate.swift
//  PCL.Mac
//
//  Created by YiZhiMCQiu on 2025/5/19.
//  Extended with --memory CLI 2026-07-22.
//

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: 注册字体
    private func registerCustomFonts() {
        guard let fontURL = Bundle.main.url(forResource: "PCL", withExtension: "ttf") else {
            err("Bundle 内未找到字体")
            return
        }

        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error) == false {
            if let error = error?.takeUnretainedValue() {
                err("无法注册字体: \(error.localizedDescription)")
            } else {
                err("在注册字体时发生未知错误")
            }
        } else {
            log("成功注册字体")
        }
    }

    // MARK: 初始化 Java 列表
    /// 后台搜索，不阻塞首屏。Java 列表只在进入设置或启动游戏时才需要，
    /// 那两条路径都已经能处理“还在搜索中”的空列表。
    private func initJavaList() {
        Task.detached(priority: .userInitiated) {
            await JavaSearch.searchAndSet()
        }
    }

    // MARK: CLI 参数处理
    // 对应上游 Application.xaml.vb 中 `If e.Args(0).StartsWithF("--memory")` 分支。
    private func handleCLIArguments() -> Bool {
        let args = CommandLine.arguments
        guard args.count > 1 else { return false }
        guard args[1].lowercased().hasPrefix("--memory") else { return false }

        // 不需要 LogStore —— 直接 stdout
        let freed = MemoryOptimizer.optimize(clearCaches: true, purgeDiskCache: false)
        print("PCL.Mac 内存优化完成，释放约 \(FileManager.humanReadableBytes(Int64(freed)))")
        exit(EXIT_SUCCESS)
    }

    // MARK: 初始化 App
    func applicationWillFinishLaunching(_ notification: Notification) {
        // CLI: --memory 提早返回，避免拉起 GUI
        if handleCLIArguments() { return }

        if !FileManager.default.fileExists(atPath: SharedConstants.shared.temperatureURL.path) {
            try? FileManager.default.createDirectory(at: SharedConstants.shared.temperatureURL, withIntermediateDirectories: true)
        }
        LogStore.shared.clear()
        let start = Date().timeIntervalSince1970
        log("App 已启动")
        _ = AppSettings.shared
        // AppSettings.init 故意不触发 GlassSettings.shared 的 dispatch_once，
        // 避免与 GlassSettings.init 形成递归锁。这里 AppSettings.shared 已完成初始化，
        // 显式把当前的 theme / accentColor 推到 GlassSettings，让首屏就能拿到正确的玻璃派生值。
        GlassSettings.shared.reloadThemeDerived()
        registerCustomFonts()
        DataManager.shared.refreshVersionManifest()

        log("正在初始化 Java 列表")
        initJavaList()
        log("App 初始化完成, 耗时 \(Int((Date().timeIntervalSince1970 - start) * 1000))ms")

        startDaemon()
    }

    /// 守护进程与首屏无关：fork/exec 放到后台队列，别占主线程。
    private func startDaemon() {
        let executableURL = SharedConstants.shared.applicationResourcesURL.appending(path: "daemon")
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            warn("未找到守护进程可执行文件，跳过启动")
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let daemonProcess = Process()
            daemonProcess.executableURL = executableURL
            do {
                try daemonProcess.run()
                log("守护进程已启动")
            } catch {
                err("无法开启守护进程: \(error.localizedDescription)")
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if AppSettings.shared.showPclMacPopup {
            Task {
                if await PopupManager.shared.showAsync(
                    .init(.normal, "欢迎使用 PCL.Mac Liquid Glass Edition", "这是面向 macOS 26 持续增强的本地版本，提供原生液态玻璃窗口、可调磨砂边框，以及完善的 PCL 启动与下载能力。\n公告、开发提示和调试路径都可以在“设置 → 其它”中关闭或自定义。", [.init(label: "不再显示", style: .normal), .close])
                ) == 0 {
                    AppSettings.shared.showPclMacPopup = false
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        LogStore.shared.save()
        LogStore.shared.flushAndClose()
        Task {
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}
