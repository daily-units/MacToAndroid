// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Waldron
// MacToAndroid 菜单栏前端
//
// 只做界面：状态面板、设备管理、询问、引导。策略全部交给 mta-ctl.sh，
// 与守护进程共用同一份实现，避免逻辑漂移。
//
// 做成常驻的菜单栏应用而不是点一次跑一次的小程序：常驻内存所以点击即出，
// 菜单是原生控件、状态不点也能看见，而且能被守护进程唤起来询问陌生设备。
//
// 编译（由 build.sh 调用）：
//   swiftc -O -o MacToAndroid MenuBar.swift

import AppKit

// MARK: - 与核心控制器通信

/// mta-ctl.sh 的一次调用。失败时返回 nil，界面据此区分「执行失败」和「返回空」。
struct Ctl {
    static var path: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/MacToAndroid/mta-ctl.sh")
    }

    /// timeout 是必须的：adb 在设备状态异常时会挂住，而菜单构建发生在主线程，
    /// 没有超时就会把整个应用卡死。超时后强制结束子进程。
    static func run(_ args: [String], timeout: TimeInterval = 8) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        // stderr 必须丢到 /dev/null 而不是一个不读的 Pipe：
        // 管道缓冲区（约 64KB）写满后子进程会永久阻塞
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        let watchdog = DispatchWorkItem {
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)

        // 必须先读完再 wait：反过来会因为管道未清空而死锁。
        // 超时被 terminate 时管道关闭，这里会立即返回。
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        let text = String(data: data, encoding: .utf8) ?? ""
        return proc.terminationStatus == 0 ? text : nil
    }

    @discardableResult
    static func runDiscard(_ args: [String], timeout: TimeInterval = 8) -> Bool {
        run(args, timeout: timeout) != nil
    }
}

/// 隧道断开是能自动修的，就不该让用户点按钮——界面只在自动修复也没解决时才提示。
/// 加时间窗防抖：修不好的情况下不要无限重试。
enum TunnelAutoRepair {
    private static var lastAttempt = Date.distantPast
    private static let minInterval: TimeInterval = 30

    /// 检测到隧道断开就后台修一次。修完回调，让调用方刷新界面。
    static func attemptIfNeeded(_ s: Summary, then done: @escaping () -> Void) {
        guard s.tunnelBroken else { return }
        guard Date().timeIntervalSince(lastAttempt) > minInterval else { return }
        lastAttempt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            Ctl.runDiscard(["repair-tunnel"])
            DispatchQueue.main.async { done() }
        }
    }

    /// 刚刚尝试过修复（用于区分「正在自动修」和「修了也没用」）
    static var recentlyAttempted: Bool {
        Date().timeIntervalSince(lastAttempt) < minInterval
    }
}

/// 状态变化的即时通知。
///
/// 守护进程每次状态转变都会**原地重写** `$TMPDIR/MacToAndroid/changed`，这里用 kqueue
/// （DispatchSource 的文件系统事件源）盯着它，收到就立刻刷新——不用等定时轮询。
/// 拔线到图标变暗从「最多 10 秒」变成 1 秒内。
///
/// 两个坑：
/// - kqueue 盯**目录**只在增删条目时触发，改文件内容不算。所以必须盯文件本身，
///   写入方也必须原地截断重写（inode 不能变），用 create+rename 就收不到。
/// - `$TMPDIR` 会被系统清理。文件被删掉之后，旧 fd 指向的 inode 再也不会有人写，
///   watch 就**静默失效**——这个项目最怕的那类故障。所以 delete/rename/revoke
///   都要重新武装，而且外层仍然保留定时轮询兜底。
private final class StateWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var stopped = false
    private var lastEvent = Date()

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm()
    }

    /// 自检：戳文件的 mtime 比我们收到的最后一次通知还新，说明这个 watch 已经不灵了
    /// （文件被删掉重建之后，旧 fd 指向的 inode 再也不会有人写）。
    /// 给 2 秒余量，避免把「通知还在路上」误判成失效。
    /// 由外层的定时轮询调用——有了这一条，watch 失效就不再是「静默降级成轮询」，
    /// 而是会被自动修复，轮询周期也就可以放宽。
    func verify() {
        guard !stopped else { return }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        guard let mtime = attrs?[.modificationDate] as? Date else {
            rearm()             // 文件不见了
            return
        }
        if mtime > lastEvent, Date().timeIntervalSince(mtime) > 2 {
            rearm()
        }
    }

    private func rearm() {
        source?.cancel()
        source = nil
        lastEvent = Date()      // 避免刚重装又被判失效
        arm()
        onChange()              // 期间可能漏了变化，补一次刷新
    }

    func stop() {
        stopped = true
        source?.cancel()
        source = nil
    }

    private func arm() {
        guard !stopped else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            // 文件还不存在（守护进程从没改过状态）也要能盯住，否则第一次变化会漏掉
            fm.createFile(atPath: path, contents: Data(),
                          attributes: [.posixPermissions: 0o600])
        }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { retry(after: 5); return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, let cur = self.source else { return }
            let ev = cur.data
            if ev.contains(.delete) || ev.contains(.rename) || ev.contains(.revoke) {
                self.source?.cancel()
                self.source = nil
                self.retry(after: 0.5)
            } else {
                self.lastEvent = Date()
                self.onChange()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func retry(after seconds: Double) {
        guard !stopped else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.arm() }
    }
}

// MARK: - 状态模型

struct Device {
    let serial: String
    let label: String
    let state: String       // shared / allowed-idle / unknown / denied / offline
    /// 仅 allowed-idle 时填充。「已允许·待启动」本身有误导性——它暗示"马上就会启动"，
    /// 而真实含义可能是"因为某个原因永远不会启动"，所以必须把原因显示出来。
    let reason: String

    var isOn: Bool { state == "shared" || state == "allowed-idle" }
    /// 设备不在线时任何逐台操作都没有可见效果，界面应该只提示「请连接设备」
    var isOffline: Bool { state == "offline" }

    var stateText: String {
        switch state {
        case "shared":       return "共享中"
        case "allowed-idle": return reason.isEmpty ? "已允许·待启动" : "待启动（\(reason)）"
        case "unknown":      return "未共享"
        case "denied":       return "已拒绝"
        default:             return "离线"
        }
    }
}

struct Summary {
    var autoOn = false
    var relayUp = false
    var shared = 0
    var dns = ""
    var ignored = 0
    var portConflict = false
    var daemonUp = true
    var port = 31416
    var depsMissing = ""        // 逗号分隔的缺失依赖，空串表示齐备
    var usbStuckCount = 0       // 插着但 adb 读不到的设备数
    var usbStuck: Bool { usbStuckCount > 0 }
    var unauthorized = 0        // adb 看得见、但手机上还没点「允许 USB 调试」
    var tunnelBroken = false    // 状态是「共享中」但 adb reverse 隧道断了
    var fdExhausted = false     // relay 文件描述符耗尽，正在丢包

    static func load() -> Summary {
        var s = Summary()
        guard let raw = Ctl.run(["summary"]) else { return s }
        for line in raw.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "auto":          s.autoOn = parts[1] == "on"
            case "relay":         s.relayUp = parts[1] == "up"
            case "shared":        s.shared = Int(parts[1]) ?? 0
            case "dns":           s.dns = parts[1]
            case "ignored":       s.ignored = Int(parts[1]) ?? 0
            case "port_conflict": s.portConflict = parts[1] == "yes"
            case "daemon":        s.daemonUp = parts[1] == "up"
            case "port":          s.port = Int(parts[1]) ?? 31416
            case "deps":          s.depsMissing = parts[1] == "ok" ? "" : parts[1]
            case "usb_stuck":     s.usbStuckCount = Int(parts[1]) ?? 0
            case "unauthorized":  s.unauthorized = Int(parts[1]) ?? 0
            case "tunnel":        s.tunnelBroken = parts[1] == "broken"
            case "fd_exhausted":  s.fdExhausted = parts[1] == "yes"
            default: break
            }
        }
        return s
    }
}

func loadDevices() -> [Device] {
    guard let raw = Ctl.run(["status"]) else { return [] }
    return raw.split(separator: "\n").compactMap { line in
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 3, !f[0].isEmpty else { return nil }
        // 只有卡在「已允许但没启动」时才去查原因——这多一次 adb 往返，
        // 但恰好是用户最需要知道原因的时刻，其余状态不付这个成本
        var reason = ""
        if f[2] == "allowed-idle" {
            // 单独给一个短超时：菜单构建在**主线程**上，而每台 allowed-idle 的设备
            // 都要多一次 why（内部是几次 adb 往返）。adb 卡住时按默认的 8 秒算，
            // 三台设备就是 8×5 秒的界面冻结。why 只是诊断信息，宁可这次拿不到。
            // （只读子命令没有 TERM trap，所以这个超时是真的硬上限——见 mta-ctl 里的注释）
            reason = (Ctl.run(["why", f[0]], timeout: 3) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Device(serial: f[0], label: f[1], state: f[2], reason: reason)
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var stateWatcher: StateWatcher?
    /// 丢弃过期刷新用。状态戳和定时器可能同时触发，先发的后到会把旧状态盖回去
    private var iconGeneration = 0
    private var pokePending = false
    private var busy = false
    /// 同 Window：ctl 最长跑到 90 秒超时，菜单项不能一直禁用那么久
    private var opToken = 0
    private var slowNote: String?
    private var askInProgress = false
    private let mainWindow = MainWindow()

    // 菜单打开时才取数据（约 110ms），不常驻轮询
    private var summary = Summary()
    private var devices: [Device] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        // 脚本与 LaunchAgent 都打在包里，第一次运行时自己铺开，
        // 所以单独下载 .app 也能用，不必先跑 build.sh
        if let err = Installer.ensure() {
            showAlert(title: "安装失败", message: err, style: .critical)
            NSApp.terminate(nil)
            return
        }

        Notify.prepare()
        refreshIcon()
        checkDependencies()
        checkPending()

        // 调试/测试用：MTA_OPEN_WINDOW=1 启动时直接打开窗口，
        // 不必先去点菜单栏（自动化测试里点不了菜单）
        if ProcessInfo.processInfo.environment["MTA_OPEN_WINDOW"] == "1" {
            mainWindow.show()
        }

        // 状态变化的即时通知。路径问 ctl 要，不自己拼 TMPDIR
        // （不同启动域下 TMPDIR 不一定是同一个）
        if let dir = Ctl.run(["state-dir"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            let stamp = (dir as NSString).appendingPathComponent("changed")
            stateWatcher = StateWatcher(path: stamp) { [weak self] in self?.stateChanged() }
        }

        // 定时轮询保留作兜底，但有了推送 + watch 自检之后不用那么勤：
        // 30 秒一跳，唤醒次数只有原来的三分之一。
        // 它现在只负责三件推送覆盖不到的事：watch 自检、守护进程死了的告警、
        // 以及「插着但 adb 读不到 / 未授权 / 依赖缺失」这类不产生 adb 事件的状态。
        // 图标对插拔的反应由状态戳负责（实测半秒内），不依赖这个周期。
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.stateWatcher?.verify()
            self?.refreshIcon()
            self?.checkPending()
        }
    }

    /// 收到状态戳。250ms 内的连续通知合成一次刷新——**只是合并请求**，
    /// 不是给「变暗」加宽限期：线掉了图标就该立刻暗下来，
    /// 否则用户看着「共享中」而手机没网，比闪一下难解释得多。
    private func stateChanged() {
        guard !pokePending else { return }
        pokePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            self.pokePending = false
            self.refreshIcon()
            self.checkPending()
        }
    }

    /// 守护进程发现陌生设备时会 open 本应用；已在运行的应用收到的是 reopen 事件
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        checkPending()
        return true
    }

    /// 直接下载 .app 的人不会先装依赖，缺了要当场说清楚怎么装，
    /// 否则界面只是显示「没有检测到设备」，看不出原因
    private func checkDependencies() {
        let s = Summary.load()
        guard !s.depsMissing.isEmpty else { return }
        let cmds = installCommands(for: s.depsMissing)
        let a = NSAlert()
        a.messageText = "缺少依赖：\(s.depsMissing)"
        a.informativeText = """
        MacToAndroid 依赖 gnirehtet（反向共享的实现）和 adb（与手机通信）。

        请在「终端」执行：

        \(cmds)

        装好后重新打开本应用。
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "复制命令")
        a.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmds, forType: .string)
        }
    }

    private func installCommands(for missing: String) -> String {
        var lines: [String] = []
        let parts = missing.split(separator: ",").map(String.init)
        if parts.contains("gnirehtet") { lines.append("brew install gnirehtet") }
        if parts.contains("adb") { lines.append("brew install --cask android-platform-tools") }
        return lines.joined(separator: "\n")
    }

    @objc private func copyInstallCommands() {
        let cmds = installCommands(for: summary.depsMissing)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmds, forType: .string)
    }

    // MARK: 菜单栏图标

    private func symbol(_ names: [String]) -> NSImage? {
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: "MacToAndroid") {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    /// 只在主线程调用：iconGeneration 靠单线程访问保证一致，没有额外加锁
    private func refreshIcon() {
        iconGeneration += 1
        let gen = iconGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Summary.load()
            DispatchQueue.main.async {
                // 有更新的请求已经在飞了（状态戳 + 定时器撞在一起），这次结果已经过期，
                // 应用它会把旧状态盖回去，产生一次莫名的闪烁
                guard gen == self.iconGeneration else { return }
                self.summary = s
                // 界面本来就在轮询状态，检测到断开直接修，不等心跳、不等用户点按钮
                TunnelAutoRepair.attemptIfNeeded(s) { [weak self] in self?.refreshIcon() }
                self.applyIcon(s)
            }
        }
    }

    /// 把一份已经取好的 summary 反映到菜单栏图标上
    private func applyIcon(_ s: Summary) {
        guard let button = statusItem.button else { return }
        // 共享中用实心图标，空闲用线框图标；符号名在不同系统版本上可能缺失，逐个回退
        // 隧道断了就不算真的在共享，图标不能显示成正常状态
        let active = s.shared > 0 && !s.tunnelBroken && !s.fdExhausted
        let candidates = active
            ? ["cable.connector.horizontal", "cable.connector", "iphone.gen3.radiowaves.left.and.right"]
            : ["cable.connector.slash", "cable.connector", "iphone.gen3"]
        if let img = symbol(candidates) {
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = active ? "⇄" : "⇢"      // 符号全都拿不到时的兜底
        }
        button.appearsDisabled = !s.autoOn
        if s.tunnelBroken {
            button.toolTip = "MacToAndroid — 隧道已断，手机有 VPN 但没网"
        } else if s.autoOn {
            button.toolTip = "MacToAndroid — 自动模式已开启，共享 \(s.shared) 台"
        } else {
            button.toolTip = "MacToAndroid — 自动模式已关闭"
        }
    }

    // MARK: 菜单构建

    func menuNeedsUpdate(_ menu: NSMenu) {
        summary = Summary.load()
        devices = loadDevices()
        // 这份 summary 是刚取的，比任何在飞的异步刷新都新：顺手把图标也同步掉。
        // 以前只更新菜单文字，图标要等下一次定时器才对得上
        iconGeneration += 1
        applyIcon(summary)
        TunnelAutoRepair.attemptIfNeeded(summary) { [weak self] in self?.refreshIcon() }
        menu.removeAllItems()

        let head = NSMenuItem(title: summary.autoOn ? "自动模式：已开启" : "自动模式：已关闭",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)

        let toggle = NSMenuItem(title: summary.autoOn ? "关闭自动模式" : "开启自动模式",
                               action: #selector(toggleAuto), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = !busy
        menu.addItem(toggle)

        menu.addItem(.separator())

        // 端口不是默认值时才显示——说明发生过自动切换，值得让用户看到
        let portNote = summary.port == 31416 ? "" : "（端口 \(summary.port)）"
        addInfo(menu, "relay        " + (summary.relayUp ? "运行中" : "未运行") + portNote)
        addInfo(menu, "共享中       \(summary.shared) 台")
        addInfo(menu, "DNS          " + (summary.dns.isEmpty ? "8.8.8.8（默认）" : summary.dns))
        if summary.ignored > 0 {
            addInfo(menu, "已忽略       \(summary.ignored) 台（模拟器 / 无线调试 / 未授权）")
        }
        if summary.portConflict {
            let warn = NSMenuItem(title: "⚠ 端口 \(summary.port) 被其他程序占用", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
        }
        if summary.fdExhausted {
            let warn = NSMenuItem(title: "⚠ relay 文件描述符耗尽，正在丢包", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            addAction(menu, "重启 relay", #selector(restartRelay))
        }
        if summary.tunnelBroken {
            // 这个状态最容易误导：手机上 VPN 图标亮着、这里写着「共享中」，但就是没网。
            // 修复是自动进行的，界面只负责说明；反复修不好时才需要用户介入。
            let text = TunnelAutoRepair.recentlyAttempted
                ? "⚠ 隧道已断，自动修复未生效"
                : "⚠ 隧道已断，正在自动修复…"
            let warn = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            if TunnelAutoRepair.recentlyAttempted {
                addAction(menu, "再试一次修复隧道", #selector(repairTunnel))
            }
        }
        if summary.usbStuckCount > 0 {
            // 这条必须常驻，不能只在设备列表为空时显示：
            // 「一台正常 + 一台卡住」时列表非空，用户只看到那台显示「离线」，
            // 完全想不到它其实插着，更不会想到换 USB 口
            let warn = NSMenuItem(
                title: "⚠ 有 \(summary.usbStuckCount) 台设备插着但 adb 读不到",
                action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            let hint = NSMenuItem(title: "　 拔插它，或换一个 USB 口", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        if summary.unauthorized > 0 {
            // 和「插着但 adb 读不到」是两回事：这台 adb 看得见，只是手机上还没授权。
            // 混在一起报会把用户支到「换 USB 口」这个完全错误的方向
            let warn = NSMenuItem(title: "⚠ 有 \(summary.unauthorized) 台设备等待授权",
                                  action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            let hint = NSMenuItem(title: "　 解锁手机，在「允许 USB 调试」弹窗里勾选「一律允许」",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
        if !summary.depsMissing.isEmpty {
            let warn = NSMenuItem(title: "⚠ 缺少依赖：\(summary.depsMissing)", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            addAction(menu, "复制安装命令", #selector(copyInstallCommands))
        }
        if let slowNote {
            let note = NSMenuItem(title: "⏳ " + slowNote, action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }
        if !summary.daemonUp {
            let warn = NSMenuItem(title: "⚠ 守护进程未运行，插线不会自动共享", action: nil, keyEquivalent: "")
            warn.isEnabled = false
            menu.addItem(warn)
            addAction(menu, "重新启动守护进程", #selector(restartDaemon))
        }

        menu.addItem(.separator())

        if devices.isEmpty {
            // 上面的常驻警告已经说明了 adb 读不到的情况，这里只区分措辞
            addInfo(menu, summary.usbStuck ? "adb 读不到任何设备" : "没有检测到设备")
        } else {
            let title = NSMenuItem(title: "设备（展开有更多操作）", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for d in devices {
                let item = NSMenuItem(title: "\(d.label)   \(d.stateText)",
                                      action: nil, keyEquivalent: "")
                item.state = d.isOn ? .on : .off
                item.toolTip = d.serial
                // 一级菜单项点击只能触发一个动作，而设备有四种操作
                // （共享 / 停止 / 拒绝 / 忘记），所以挂子菜单。
                // 拒绝与忘记之前只能从陌生设备弹窗或命令行做，界面里没有入口。
                item.submenu = deviceSubmenu(for: d)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addAction(menu, "打开窗口", #selector(openWindow))
        addAction(menu, "环境自检…", #selector(showDoctor))
        addAction(menu, "打开日志文件夹", #selector(openLogs))
        // 破坏性操作，刻意不放在「退出」旁边
        addAction(menu, "卸载 MacToAndroid…", #selector(uninstallSelf))
        menu.addItem(.separator())
        addAction(menu, "退出 MacToAndroid", #selector(quit))
    }

    /// 按钮随状态变化，避免语义重叠。
    ///
    /// 一台设备不可能同时「已允许」和「已拒绝」，所以「停止共享」和「清除记录」
    /// 永远不会同时出现——早期版本三个按钮并列（停止共享 / 拒绝 / 忘记），
    /// 而「忘记」对已允许的设备与「停止共享」完全等价，只是多清了一个不存在的
    /// deny 记录，用户看不出区别。
    private func deviceSubmenu(for d: Device) -> NSMenu {
        let sub = NSMenu()

        // 离线设备不给任何操作入口。
        // 以前这里是「开始共享」（其实只是预先写 allow 记录）和「不再询问」——
        // 点了界面没有任何可见变化，看起来就是按钮坏了。
        // 记录层面的增删仍然可以用 CLI（mta-ctl allow / deny / forget）。
        if d.isOffline {
            let hint = NSMenuItem(title: "请连接设备", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
            sub.addItem(.separator())
            let info = NSMenuItem(title: "序列号 \(d.serial)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            return sub
        }

        // 卡在「待启动」且已知原因时，这里是唯一的修复入口。
        // allowed-idle 的 isOn 是 true，所以下面的切换按钮显示的是「停止共享」——
        // 没有这一项的话，用户想触发引导只能先停止再开始，等于没有入口。
        if d.state == "allowed-idle", !d.reason.isEmpty {
            let fix = NSMenuItem(title: "解决：\(d.reason)",
                                 action: #selector(fixDevice(_:)), keyEquivalent: "")
            fix.target = self
            fix.representedObject = d.serial
            fix.isEnabled = !busy
            sub.addItem(fix)
            sub.addItem(.separator())
        }

        // 「共享中」和「已允许但没跑起来」是两种状态。对后者也说「停止共享」，
        // 会让人以为正在共享——手机上没有 VPN、按钮却写着「停止共享」，正是这么来的
        let stopTitle = d.state == "shared" ? "停止共享" : "取消共享"
        let toggle = NSMenuItem(title: d.isOn ? stopTitle : "开始共享",
                                action: #selector(toggleDevice(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.representedObject = d.serial
        toggle.isEnabled = !busy
        sub.addItem(toggle)

        if d.state == "denied" {
            // 已拒绝的设备唯一不可替代的操作：回到「未共享」而不直接允许，
            // 下次连接会重新询问
            let forget = NSMenuItem(title: "清除记录（下次连接重新询问）",
                                    action: #selector(forgetDevice(_:)), keyEquivalent: "")
            forget.target = self
            forget.representedObject = d.serial
            forget.isEnabled = !busy
            sub.addItem(forget)
        } else {
            let deny = NSMenuItem(title: "不再询问", action: #selector(denyDevice(_:)), keyEquivalent: "")
            deny.target = self
            deny.representedObject = d.serial
            deny.isEnabled = !busy
            sub.addItem(deny)
        }

        sub.addItem(.separator())
        let info = NSMenuItem(title: "序列号 \(d.serial)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        sub.addItem(info)
        return sub
    }

    private func addInfo(_ menu: NSMenu, _ text: String) {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: 动作

    /// 改状态的操作放后台执行：reconcile 可能要几百毫秒，不能卡住菜单
    private func perform(_ args: [String], failTitle: String, notice: String? = nil) {
        busy = true
        slowNote = nil
        opToken += 1
        let token = opToken
        // 8 秒后先放开菜单项：否则 adb 挂住时，接下来 90 秒里打开菜单看到的是
        // 一整片灰掉的选项，而且没有任何解释
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.opToken == token, self.busy else { return }
            self.busy = false
            self.slowNote = "上一个操作还在处理（adb 可能卡住了）"
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 8 秒（默认值）短于最坏路径：`auto on` 要对每台设备走一次 client_start
            // （relay 起来最多 5 秒 + 等客户端连上最多 6 秒），还可能先排队等锁最多 30 秒。
            // 超时被 watchdog 杀掉后界面弹「执行失败」，而状态其实已经改了——
            // 比真失败更让人困惑。这里跑在后台线程，给足时间。
            let ok = Ctl.runDiscard(args, timeout: 90)
            DispatchQueue.main.async {
                if self.opToken == token { self.slowNote = nil }
                self.busy = false
                self.refreshIcon()
                if ok, let notice {
                    // 菜单点完就关了，异步操作完成时界面已不在眼前
                    Notify.post("MacToAndroid", notice)
                }
                if !ok {
                    self.showAlert(title: failTitle,
                                   message: "控制器执行失败。常见原因是另一个操作正在进行（守护进程正在对账），稍等几秒再试。",
                                   style: .warning)
                }
            }
        }
    }

    @objc private func toggleAuto() {
        let turningOn = !summary.autoOn
        perform(["auto", turningOn ? "on" : "off"],
                failTitle: "切换自动模式失败",
                notice: turningOn ? "自动模式已开启" : "自动模式已关闭，所有共享已断开")

        // 没有任何设备在线时开启自动模式，界面上看不出发生了什么。
        // 这里不阻塞等待设备：本应用是常驻的，插线后守护进程会自动处理，
        // 所以只需说明一句，让用户知道「现在什么都不会发生」是正常的
        if turningOn, devices.allSatisfy({ $0.state == "offline" }) {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = "自动模式已开启"
            a.informativeText = "当前没有已连接的设备。插上开启了 USB 调试的 Android 设备后会自动处理，不需要再点任何东西。"
            a.alertStyle = .informational
            a.addButton(withTitle: "好")
            a.runModal()
        }
    }

    /// 按序列号找回设备。菜单每次打开都会重建，但设备列表可能在这之间变过，
    /// 用下标就可能把操作打到另一台设备上
    private func device(for sender: NSMenuItem) -> Device? {
        guard let serial = sender.representedObject as? String else { return nil }
        return devices.first(where: { $0.serial == serial })
    }

    @objc private func toggleDevice(_ sender: NSMenuItem) {
        guard let d = device(for: sender), !d.isOffline else { return }
        if d.isOn {
            perform(["unshare", d.serial], failTitle: "停止共享失败",
                    notice: "\(d.label) 已停止共享")
        } else {
            // 走引导：条件不满足时逐项解决，而不是静默停在「已允许·待启动」
            Guide.share(serial: d.serial, label: d.label) { [weak self] in self?.refreshIcon() }
        }
    }

    /// 走完整的引导流程去解决阻塞原因（装客户端、重装、开开关…）
    @objc private func fixDevice(_ sender: NSMenuItem) {
        guard let d = device(for: sender) else { return }
        Guide.share(serial: d.serial, label: d.label) { [weak self] in self?.refreshIcon() }
    }

    @objc private func denyDevice(_ sender: NSMenuItem) {
        guard let d = device(for: sender) else { return }
        let a = NSAlert()
        a.messageText = "不再询问这台设备？"
        a.informativeText = "\(d.label)\n\(d.serial)\n\n之后插上它不会共享网络，也不会弹窗询问。可以随时用「开始共享」或「清除记录」撤销。"
        a.alertStyle = .warning
        a.addButton(withTitle: "不再询问")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        perform(["deny", d.serial], failTitle: "拒绝失败",
                notice: "\(d.label) 已加入拒绝列表，不会再询问")
    }

    @objc private func forgetDevice(_ sender: NSMenuItem) {
        guard let d = device(for: sender) else { return }
        perform(["forget", d.serial], failTitle: "忘记失败",
                notice: "\(d.label) 的记录已清除，下次连接会重新询问")
    }

    @objc private func restartRelay() {
        perform(["health"], failTitle: "重启 relay 失败")
    }

    @objc private func repairTunnel() {
        perform(["repair-tunnel"], failTitle: "修复隧道失败")
    }

    @objc private func restartDaemon() {
        // 重新跑一次自装即可：它发现服务未加载会自动 bootstrap
        Installer.ensure()
        refreshIcon()
    }

    @objc private func openWindow() {
        mainWindow.show()
    }

    @objc private func showDoctor() {
        var text = Ctl.run(["doctor"]) ?? "无法执行环境自检"
        // 机器上可能存在多份 .app（构建产物、下载目录里的旧版）。doctor 里的 app_path
        // 是**守护进程会去唤起**的那一份，未必是当前这个界面所在的副本——不写出来
        // 会让「明明点了这份、行为却像另一份」变得完全无从判断
        let running = Bundle.main.bundlePath
        text += "\nrunning_app\t\(running)"
        if !text.contains("app_path\t\(running)") {
            text += "\n⚠\t当前界面所在副本与 app_path 不一致：守护进程唤起的是 app_path 那一份"
        }
        showAlert(title: "环境自检", message: text, style: .informational)
    }

    @objc private func openLogs() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/MacToAndroid")
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    /// 卸载入口。
    ///
    /// 为什么非要有：这个 App 装了两个 LaunchAgent，而**把 .app 拖进废纸篓并不会带走它们**
    /// ——守护进程照样开机自启、插线照样共享，用户却以为已经卸掉了。macOS 对
    /// LaunchAgent 没有任何自动清理机制（「登录项与扩展」只能停用、删不掉 plist），
    /// 所以装了后台组件的软件必须自带卸载器。
    @objc private func uninstallSelf() {
        guard let script = uninstallScriptPath() else {
            showAlert(title: "找不到卸载脚本",
                      message: """
                      运行目录和应用包里都没有 uninstall.sh。手动清理：

                      launchctl bootout "gui/$UID/com.local.mactoandroid.menubar"
                      launchctl bootout "gui/$UID/com.local.mactoandroid"
                      rm -f ~/Library/LaunchAgents/com.local.mactoandroid*.plist
                      rm -rf ~/Library/"Application Support"/MacToAndroid
                      rm -rf ~/.config/mactoandroid ~/Library/Logs/MacToAndroid
                      rm -rf /Applications/MacToAndroid.app
                      """,
                      style: .warning)
            return
        }

        let a = NSAlert()
        a.messageText = "卸载 MacToAndroid？"
        a.informativeText = """
        将会：
        • 停止共享，并掐掉手机端的 VPN
        • 卸载并删除两个后台登录项（守护进程、菜单栏自启）
        • 删除 ~/Library/Application Support/MacToAndroid
        • 删除应用本身

        本应用会立刻退出。过程记录在
        ~/Library/Logs/MacToAndroid-uninstall.log
        """
        a.alertStyle = .warning
        // 用抑制勾选框承载「顺便清数据」这个选项，省掉第三个按钮
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "同时清除设备列表与日志，并卸载手机端客户端"
        a.addButton(withTitle: "卸载")
        a.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }

        var args = [script, "--yes"]
        if a.suppressionButton?.state == .on { args.append("--purge") }

        // 日志放在 MacToAndroid 日志目录**之外**——--purge 会把那个目录整个删掉
        let log = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/MacToAndroid-uninstall.log")
        let fm = FileManager.default
        if !fm.fileExists(atPath: log) { fm.createFile(atPath: log, contents: nil) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = args
        if let fh = FileHandle(forWritingAtPath: log) {
            fh.seekToEndOfFile()
            p.standardOutput = fh
            p.standardError = fh
        }
        // 脚本第一件事就是结束本 App，所以**绝不能等它**。
        // 子进程被孤儿化没问题——父进程死后它会被 launchd 收养，继续跑完。
        try? p.run()
    }

    private func uninstallScriptPath() -> String? {
        let runtime = (Installer.runtimeDir as NSString).appendingPathComponent("uninstall.sh")
        if FileManager.default.isExecutableFile(atPath: runtime) { return runtime }
        // 运行目录里没有（老版本装的）就用包里那份：脚本会删掉整个 .app，
        // 但 bash 已经打开了这个文件，unlink 之后仍然能读完，所以是安全的
        return Bundle.main.path(forResource: "uninstall.sh", ofType: nil)
    }

    @objc private func quit() {
        // 只退出界面，守护进程与共享不受影响——这一点要说清楚，否则用户会以为共享也停了
        let a = NSAlert()
        a.messageText = "退出菜单栏图标？"
        a.informativeText = "共享不会中断，后台守护进程仍在运行。要完全停止请先「关闭自动模式」。"
        a.addButton(withTitle: "退出")
        a.addButton(withTitle: "取消")
        a.alertStyle = .informational
        if a.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    // MARK: 陌生设备询问

    private func checkPending() {
        guard !askInProgress else { return }
        guard let raw = Ctl.run(["pending"]) else { return }
        let serials = raw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !serials.isEmpty else { return }

        // pending-ask 在 ~/.config 下是持久的，而「本次连接已问过」的记录在 $TMPDIR 里
        // 开机即失效。App 没运行时排进来的条目可能几天后才被读到——那时设备早拔了。
        // 弹窗问一台不在场的设备毫无意义，点「共享」还会把它写进允许列表。
        // 守护进程那边也会清（prune_pending），这里再挡一道。
        let current = loadDevices()
        var ask: [String] = []
        for s in serials {
            if current.first(where: { $0.serial == s })?.state == "unknown" {
                ask.append(s)
            } else {
                Ctl.runDiscard(["resolve", s])
            }
        }
        guard !ask.isEmpty else { return }
        askInProgress = true
        askNext(ask)
    }

    private func askNext(_ queue: [String]) {
        guard let serial = queue.first else {
            askInProgress = false
            // 处理期间可能又排进了新设备
            checkPending()
            return
        }
        let rest = Array(queue.dropFirst())
        let label = devices.first(where: { $0.serial == serial })?.label
            ?? loadDevices().first(where: { $0.serial == serial })?.label
            ?? serial

        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "发现新设备"
        a.informativeText = "\(label)\n\(serial)\n\n要把这台 Mac 的网络通过数据线共享给它吗？"
        a.alertStyle = .informational
        a.addButton(withTitle: "共享")
        a.addButton(withTitle: "以后再说")
        a.addButton(withTitle: "拒绝并不再询问")
        let r = a.runModal()

        Ctl.runDiscard(["resolve", serial])
        switch r {
        case .alertFirstButtonReturn:
            // 引导是异步的。以前这里紧接着 askNext(rest) 弹出下一台的询问框，
            // 而这台的引导弹窗随后会盖在它上面——用户在回答第二台，第一台的引导却冒出来。
            // 所以等这台走完再问下一台。
            //
            // 两处保险：refresh 在个别路径上可能被调用多次，用一次性标记保证只继续一次；
            // 万一某条路径忘了回调，5 分钟后兜底继续——否则 askInProgress 会永久为真，
            // 之后所有陌生设备都不会再被询问。
            var continued = false
            let advance: () -> Void = { [weak self] in
                guard !continued else { return }
                continued = true
                self?.askNext(rest)
            }
            Guide.share(serial: serial, label: label) { [weak self] in
                self?.refreshIcon()
                advance()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: advance)
            return
        case .alertThirdButtonReturn:
            Ctl.runDiscard(["deny", serial])
            refreshIcon()
        default:
            break
        }
        askNext(rest)
    }

    // MARK: 工具

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = style
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

/// 启动位置检查：不在「应用程序」里就提示用户移过去。
///
/// 为什么要管这件事：登录项和守护进程「唤起 App」用的都是**当前这个 bundle 的绝对路径**
/// （见 `Installer`）。从「下载」、桌面、`dist/` 这类位置运行，位置一变或副本被删，
/// 开机自启就静默失效——而且不会有任何报错。从 DMG 里直接运行更糟：卸载后路径就没了。
///
/// 所以这个判断必须排在 `Installer.ensure()` **之前**，晚一步路径就已经被记下去了。
private enum LaunchLocation {

    /// 返回 true 表示本进程应当退出（已经移动并重新打开，或用户选择退出）
    static func checkAndPromptIfNeeded() -> Bool {
        let path = Bundle.main.bundlePath
        if isAcceptable(path) || wasApproved(path) { return false }

        // 带隔离标记从「下载」里双击时，系统会把 App 挂到一个只读的随机路径上
        // （App Translocation）。那种情况下没法「移动」——真实位置不在这里，
        // 只能让用户自己去掉隔离标记或手动拖进「应用程序」。
        if path.contains("/AppTranslocation/") {
            let a = NSAlert()
            a.messageText = "请先把 MacToAndroid 拖进「应用程序」"
            a.informativeText = """
            系统把这个应用放在了一个只读的临时位置运行（App Translocation），
            因为它带着「从网上下载」的隔离标记。这种状态下开机自启无法可靠工作。

            请退出后：把 MacToAndroid.app 拖进「应用程序」，或先执行

                xattr -dr com.apple.quarantine <MacToAndroid.app 的路径>

            然后再打开。
            """
            a.alertStyle = .warning
            a.addButton(withTitle: "退出")
            a.addButton(withTitle: "仍在此处运行")
            NSApp.activate(ignoringOtherApps: true)
            if a.runModal() == .alertFirstButtonReturn { return true }
            approve(path)
            return false
        }

        let dest = "/Applications/" + (path as NSString).lastPathComponent
        let destExists = FileManager.default.fileExists(atPath: dest)

        let a = NSAlert()
        a.messageText = "把 MacToAndroid 移到「应用程序」？"
        a.informativeText = destExists
            ? """
            当前运行的是：
            \(path)

            而「应用程序」里已经有一份了。开机自启会指向你**实际运行的那一份**，
            两份并存容易搞混，建议直接用「应用程序」里的那份。
            """
            : """
            当前运行的是：
            \(path)

            开机自启和「插入新设备时唤起界面」都记录 App 的绝对路径。
            留在「下载」、桌面或构建目录里运行，位置一变或这份副本被删，
            开机自启就会静默失效。
            """
        a.alertStyle = .informational
        if destExists {
            a.addButton(withTitle: "打开「应用程序」里那一份")
        } else {
            a.addButton(withTitle: "移动并重新打开")
        }
        a.addButton(withTitle: "仍在此处运行")
        a.addButton(withTitle: "退出")
        NSApp.activate(ignoringOtherApps: true)

        switch a.runModal() {
        case .alertFirstButtonReturn:
            if destExists { relaunch(dest); return true }
            if let err = move(from: path, to: dest) {
                let f = NSAlert()
                f.messageText = "移动失败"
                f.informativeText = "\(err)\n\n可以手动把它拖进「应用程序」，或选择「仍在此处运行」。"
                f.alertStyle = .warning
                f.addButton(withTitle: "好")
                f.runModal()
                return false        // 移动失败就继续在原地跑，别把用户卡在这里
            }
            relaunch(dest)
            return true
        case .alertSecondButtonReturn:
            approve(path)           // 记下来，下次不再问
            return false
        default:
            return true
        }
    }

    private static func isAcceptable(_ path: String) -> Bool {
        let userApps = (NSHomeDirectory() as NSString).appendingPathComponent("Applications") + "/"
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApps)
    }

    // 「仍在此处运行」记的是**具体路径**：换个位置还是该再问一次
    private static var approvalFile: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent(".config/mactoandroid/allow-outside-applications")
    }

    private static func wasApproved(_ path: String) -> Bool {
        guard let saved = try? String(contentsOfFile: approvalFile, encoding: .utf8) else { return false }
        return saved.trimmingCharacters(in: .whitespacesAndNewlines) == path
    }

    private static func approve(_ path: String) {
        let dir = (approvalFile as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (path + "\n").write(toFile: approvalFile, atomically: true, encoding: .utf8)
    }

    /// 返回 nil 表示成功，否则是给用户看的错误描述
    private static func move(from src: String, to dest: String) -> String? {
        let fm = FileManager.default
        do {
            try fm.moveItem(atPath: src, toPath: dest)
            return nil
        } catch {
            // 跨卷（比如从 DMG）时 moveItem 可能因为删不掉源而失败，退回复制
            do {
                try fm.copyItem(atPath: src, toPath: dest)
                return nil
            } catch let e {
                return e.localizedDescription
            }
        }
    }

    /// 重新打开移动后的那一份。
    ///
    /// 必须**延迟**再 open：新实例启动时如果本进程还活着，它的单实例判断会发现
    /// 有一个更早启动的实例，于是自己退出——两边互相让位，结果谁都没起来。
    /// 所以让一个脱离出去的 shell 等一秒再 open，本进程立刻退出。
    private static func relaunch(_ dest: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$1\"", "sh", dest]
        try? p.run()
    }
}

@main
enum MacToAndroidMenuBar {

    /// 同一个 bundle id 的第二份副本不该起来。
    ///
    /// 后果不只是状态栏出现两个图标：`Installer` 写 `app-path` 和登录项时用的是
    /// **自己的** bundle 路径，所以后启动的那份会把开机自启和守护进程的「唤起 App」
    /// 都改指向它自己——那份副本一删（比如 dist/ 被 release.sh 清掉）就静默失效，
    /// 而且改 plist 会再触发一次系统的「后台项目已添加」通知。
    /// 两个前端还会各自轮询、各自弹一次「发现新设备」。
    ///
    /// 所以在做任何事之前先检查。判断谁该退出要有确定的先后（按启动时间、pid 兜底），
    /// 否则两份几乎同时启动时可能互相谦让、两个都退掉。
    private static func shouldYieldToRunningInstance() -> Bool {
        guard let bid = Bundle.main.bundleIdentifier else { return false }
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
            .filter { $0.processIdentifier != me.processIdentifier }
        let mine = me.launchDate ?? Date.distantFuture
        for other in others {
            let theirs = other.launchDate ?? Date.distantFuture
            if theirs < mine || (theirs == mine && other.processIdentifier < me.processIdentifier) {
                other.activate(options: [])
                return true
            }
        }
        return false
    }

    static func main() {
        let app = NSApplication.shared
        // 必须在 Installer.ensure() 之前判断，否则副本已经把登录项改掉了
        if shouldYieldToRunningInstance() { return }
        // 同理：位置检查也要早于 ensure()，否则登录项已经指向了临时位置
        if LaunchLocation.checkAndPromptIfNeeded() { return }
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 只在菜单栏，不占 Dock
        app.run()
    }
}
