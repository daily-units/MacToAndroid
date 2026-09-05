// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Waldron
// MacToAndroid 主窗口
//
// 菜单栏适合快速切换，但设备多、要看拒绝列表、要做拒绝/忘记这类操作时，
// 一个能同时看到全部信息的窗口更合适。这里用纯代码搭 AppKit 视图，
// 不引入 xib/storyboard，这样 build.sh 里一条 swiftc 就能编译。

import AppKit

/// AppKit 的视图默认不翻转（原点在左下）。当 NSScrollView 的文档视图比可视区域短时，
/// 内容会被贴在**底部**——设备列表就出现在「设备」标题下方一大段空白之后。
/// 让文档视图翻转，布局才从上往下。
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 按钮上挂**序列号**，而不是数组下标。
/// 窗口每 5 秒重建一次设备行：拔掉一台之后列表会变短、顺序会变，而下标是在
/// 构建那一刻算出来的——点击落到 action 时可能已经指向另一台设备。
/// 「不再询问」被打到别人身上很难解释，所以身份必须跟着按钮走。
private final class DeviceButton: NSButton {
    var serial: String = ""
}

final class MainWindow: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var deviceStack: NSStackView!
    private var headerLabel: NSTextField!
    private var toggleButton: NSButton!
    private var infoLabel: NSTextField!
    private var warnLabel: NSTextField!
    private var refreshTimer: Timer?
    private var busy = false
    /// 慢操作的标记。ctl 最长会跑到 90 秒超时，按钮不能一直禁用那么久
    private var opToken = 0
    private var slowNote: String?

    private var devices: [Device] = []
    private var summary = Summary()

    /// 菜单栏应用是 LSUIElement，不激活的话窗口会出现在其他应用后面
    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refresh()
        startTimer()
    }

    // MARK: 构建

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "MacToAndroid"
        w.delegate = self
        w.isReleasedWhenClosed = false      // 关掉只是隐藏，下次打开复用
        w.center()
        w.minSize = NSSize(width: 460, height: 320)

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        // —— 顶部：自动模式 + 开关
        headerLabel = label("", size: 15, bold: true)
        toggleButton = NSButton(title: "", target: self, action: #selector(toggleAuto))
        toggleButton.bezelStyle = .rounded

        let headRow = NSStackView(views: [headerLabel, spacer(), toggleButton])
        headRow.orientation = .horizontal
        headRow.spacing = 12
        root.addView(headRow, in: .top)
        headRow.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true

        root.addView(separator(), in: .top)

        // —— 概要
        infoLabel = label("", size: 12, bold: false)
        infoLabel.textColor = .secondaryLabelColor
        root.addView(infoLabel, in: .top)

        warnLabel = label("", size: 12, bold: false)
        warnLabel.textColor = .systemOrange
        warnLabel.isHidden = true
        root.addView(warnLabel, in: .top)

        root.addView(separator(), in: .top)
        root.addView(label("设备", size: 13, bold: true), in: .top)

        // —— 设备列表（可滚动）
        deviceStack = NSStackView()
        deviceStack.orientation = .vertical
        deviceStack.alignment = .leading
        deviceStack.spacing = 8
        deviceStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedView()
        clip.translatesAutoresizingMaskIntoConstraints = false
        clip.addSubview(deviceStack)
        NSLayoutConstraint.activate([
            deviceStack.topAnchor.constraint(equalTo: clip.topAnchor),
            deviceStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            deviceStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            // 用 >= 而不是 ==：设备少时文档视图不该被内容撑开或压缩，
            // 由 clip 自己撑满滚动区域，内容靠翻转坐标系留在顶部
            clip.bottomAnchor.constraint(greaterThanOrEqualTo: deviceStack.bottomAnchor),
        ])
        scroll.documentView = clip
        // 纵向滚动时文档视图的宽度必须绑到剪切视图，否则内容不会撑满
        clip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        root.addView(scroll, in: .top)
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        // —— 底部工具按钮
        let footer = NSStackView(views: [
            smallButton("刷新", #selector(refreshClicked)),
            smallButton("修复隧道", #selector(repairClicked)),
            smallButton("环境自检…", #selector(doctorClicked)),
            smallButton("打开日志文件夹", #selector(logsClicked)),
            spacer(),
        ])
        footer.orientation = .horizontal
        footer.spacing = 10
        root.addView(footer, in: .top)
        footer.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        w.contentView = content
        window = w
    }

    private func label(_ text: String, size: CGFloat, bold: Bool) -> NSTextField {
        let t = NSTextField(labelWithString: text)
        t.font = bold ? .systemFont(ofSize: size, weight: .semibold) : .systemFont(ofSize: size)
        t.lineBreakMode = .byWordWrapping
        return t
    }

    private func spacer() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        return v
    }

    private func separator() -> NSBox {
        let b = NSBox()
        b.boxType = .separator
        return b
    }

    private func smallButton(_ title: String, _ sel: Selector, serial: String = "") -> DeviceButton {
        let b = DeviceButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        b.serial = serial
        return b
    }

    // MARK: 刷新

    private func startTimer() {
        refreshTimer?.invalidate()
        // 窗口开着时定期刷新，让插拔设备后不用手动点刷新
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.window?.isVisible == true else { return }
            self.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            let s = Summary.load()
            let d = loadDevices()
            DispatchQueue.main.async {
                self.summary = s
                self.devices = d
                self.render()
                // 窗口本来就在 5 秒轮询，检测到断开直接修，不要求用户点按钮
                TunnelAutoRepair.attemptIfNeeded(s) { [weak self] in self?.refresh() }
            }
        }
    }

    private func render() {
        headerLabel.stringValue = summary.autoOn ? "自动模式：已开启" : "自动模式：已关闭"
        toggleButton.title = summary.autoOn ? "关闭自动模式" : "开启自动模式"
        toggleButton.isEnabled = !busy

        var parts = [
            "relay " + (summary.relayUp ? "运行中" : "未运行")
                + (summary.port == 31416 ? "" : "（端口 \(summary.port)）"),
            "共享 \(summary.shared) 台",
            "DNS " + (summary.dns.isEmpty ? "8.8.8.8（默认）" : summary.dns),
        ]
        if summary.ignored > 0 { parts.append("已忽略 \(summary.ignored) 台") }
        infoLabel.stringValue = parts.joined(separator: "　·　")

        var warns: [String] = []
        if summary.fdExhausted {
            warns.append("⚠ relay 文件描述符耗尽，正在丢包。心跳会自动重启它（约 60 秒内）")
        }
        if summary.tunnelBroken {
            warns.append(TunnelAutoRepair.recentlyAttempted
                ? "⚠ 隧道已断，自动修复未生效。可点「修复隧道」再试，或拔插数据线"
                : "⚠ 隧道已断，正在自动修复…")
        }
        if summary.portConflict { warns.append("⚠ 端口 \(summary.port) 被其他程序占用，relay 无法启动") }
        if !summary.daemonUp { warns.append("⚠ 守护进程未运行，插线不会自动共享") }
        if !summary.depsMissing.isEmpty {
            warns.append("⚠ 缺少依赖：\(summary.depsMissing)（用 brew 安装后重开本应用）")
        }
        if summary.usbStuckCount > 0 {
            warns.append("⚠ 有 \(summary.usbStuckCount) 台设备插着但 adb 读不到。拔插它，或换一个 USB 口（某些口接触不良会反复触发）")
        }
        if let slowNote { warns.append("⏳ " + slowNote) }
        // 和上一条是两回事：这台 adb 看得见，只是手机上还没点「允许 USB 调试」。
        // 混在一起报会把用户支到「换 USB 口」这个完全错误的方向
        if summary.unauthorized > 0 {
            warns.append("⚠ 有 \(summary.unauthorized) 台设备等待授权：解锁手机，在「允许 USB 调试」弹窗里勾选「一律允许」")
        }
        warnLabel.stringValue = warns.joined(separator: "\n")
        warnLabel.isHidden = warns.isEmpty

        for v in deviceStack.views { deviceStack.removeView(v) }

        if devices.isEmpty {
            let emptyText = summary.usbStuck
                ? "adb 读不到任何设备。见上方提示。"
                : "没有检测到设备。插上已开启 USB 调试的 Android 设备。"
            let empty = label(emptyText, size: 12, bold: false)
            empty.textColor = .secondaryLabelColor
            deviceStack.addView(empty, in: .top)
            return
        }

        for d in devices {
            let row = deviceRow(d)
            deviceStack.addView(row, in: .top)
            // 必须先入栈再加约束：两个视图在同一层级之前没有共同祖先，
            // 提前激活会抛 NSGenericException 让整个应用崩溃
            row.widthAnchor.constraint(equalTo: deviceStack.widthAnchor).isActive = true
        }
    }

    private func deviceRow(_ d: Device) -> NSView {
        let name = label(d.label, size: 13, bold: true)
        let serial = label(d.serial + "　" + d.stateText, size: 11, bold: false)
        serial.textColor = .secondaryLabelColor

        let text = NSStackView(views: [name, serial])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        // 离线设备不给按钮：点「开始共享」只是预先写一条 allow 记录、点「不再询问」
        // 只是写一条 deny 记录，界面上没有任何可见变化，看起来就是按钮没反应。
        // 记录层面的增删仍可用 CLI（mta-ctl allow / deny / forget）。
        if d.isOffline {
            let hint = label("请连接设备", size: 11, bold: false)
            hint.textColor = .secondaryLabelColor
            let row = NSStackView(views: [text, spacer(), hint])
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
            row.wantsLayer = true
            row.layer?.cornerRadius = 6
            row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
            return row
        }

        // 按钮随状态变化：一台设备不可能同时「已允许」和「已拒绝」，
        // 所以「停止共享」和「清除记录」永远不会同时出现，不存在语义重叠。
        // 同菜单：allowed-idle 说「停止共享」会误导，它其实什么都没在跑
        let stopTitle = d.state == "shared" ? "停止共享" : "取消共享"
        let toggle = smallButton(d.isOn ? stopTitle : "开始共享", #selector(rowToggle(_:)),
                                 serial: d.serial)
        toggle.isEnabled = !busy

        let second: DeviceButton
        if d.state == "denied" {
            second = smallButton("清除记录", #selector(rowForget(_:)), serial: d.serial)
        } else {
            second = smallButton("不再询问", #selector(rowDeny(_:)), serial: d.serial)
        }
        second.isEnabled = !busy

        // 卡在「待启动」且已知原因时，这里是唯一的修复入口：
        // allowed-idle 的 isOn 是 true，切换按钮显示的是「停止共享」，
        // 没有这个按钮用户就无从触发引导
        var views: [NSView] = [text, spacer()]
        if d.state == "allowed-idle", !d.reason.isEmpty {
            let fix = smallButton("解决问题", #selector(rowFix(_:)), serial: d.serial)
            fix.isEnabled = !busy
            views.append(fix)
        }
        views.append(toggle)
        views.append(second)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.wantsLayer = true
        row.layer?.cornerRadius = 6
        row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        // 宽度约束由调用方在入栈之后添加
        return row
    }

    // MARK: 动作

    private func perform(_ args: [String], failTitle: String, notice: String? = nil) {
        busy = true
        slowNote = nil
        opToken += 1
        let token = opToken
        render()
        // adb 真挂住时 ctl 要一直跑到 90 秒超时才回来。把按钮禁用到那时候，
        // 界面看起来就是死了（这是把超时从 8 秒提到 90 秒时带来的副作用）。
        // 所以 8 秒后先把按钮放开、在告警行说明「还在处理」，
        // 操作继续在后台跑完，结果回来时再刷新一次。
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.opToken == token, self.busy else { return }
            self.busy = false
            self.slowNote = "上一个操作还在处理（adb 可能卡住了），可以稍后重试"
            self.render()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // 8 秒（Ctl.run 的默认值）短于最坏路径：`auto on` 要对每台设备走一次
            // client_start（relay 起来最多 5 秒 + 等客户端连上最多 6 秒），
            // 还可能先排队等锁最多 30 秒。超时会被 watchdog 杀掉，界面弹「执行失败」，
            // 而状态其实已经改了——比真失败更让人困惑。这里跑在后台线程，给足时间。
            let ok = Ctl.runDiscard(args, timeout: 90)
            DispatchQueue.main.async {
                if self.opToken == token { self.slowNote = nil }
                self.busy = false
                if ok, let notice { Notify.post("MacToAndroid", notice) }
                if !ok {
                    let a = NSAlert()
                    a.messageText = failTitle
                    a.informativeText = "控制器执行失败。常见原因是另一个操作正在进行（守护进程正在对账），稍等几秒再试。"
                    a.alertStyle = .warning
                    a.addButton(withTitle: "好")
                    a.runModal()
                }
                self.refresh()
            }
        }
    }

    /// 按序列号找回设备。列表随时可能被 5 秒一次的刷新换掉，
    /// 所以只认按钮上带的序列号，不认位置
    private func device(for sender: Any?) -> Device? {
        guard let serial = (sender as? DeviceButton)?.serial else { return nil }
        return devices.first(where: { $0.serial == serial })
    }

    @objc private func toggleAuto() {
        let turningOn = !summary.autoOn
        perform(["auto", turningOn ? "on" : "off"],
                failTitle: "切换自动模式失败",
                notice: turningOn ? "自动模式已开启" : "自动模式已关闭，所有共享已断开")
    }

    @objc private func rowToggle(_ sender: NSButton) {
        guard let d = device(for: sender), !d.isOffline else { return }
        if d.isOn {
            perform(["unshare", d.serial], failTitle: "停止共享失败",
                    notice: "\(d.label) 已停止共享")
        } else {
            // 走引导：条件不满足时逐项解决，而不是静默停在「已允许·待启动」
            Guide.share(serial: d.serial, label: d.label) { [weak self] in self?.refresh() }
        }
    }

    /// 走完整的引导流程去解决阻塞原因
    @objc private func rowFix(_ sender: NSButton) {
        guard let d = device(for: sender) else { return }
        Guide.share(serial: d.serial, label: d.label) { [weak self] in self?.refresh() }
    }

    @objc private func rowDeny(_ sender: NSButton) {
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

    @objc private func rowForget(_ sender: NSButton) {
        guard let d = device(for: sender) else { return }
        perform(["forget", d.serial], failTitle: "忘记失败",
                notice: "\(d.label) 的记录已清除，下次连接会重新询问")
    }

    @objc private func refreshClicked() { refresh() }

    @objc private func repairClicked() {
        perform(["repair-tunnel"], failTitle: "修复隧道失败")
    }

    @objc private func doctorClicked() {
        let text = Ctl.run(["doctor"]) ?? "无法执行环境自检"
        let a = NSAlert()
        a.messageText = "环境自检"
        a.informativeText = text
        a.alertStyle = .informational
        a.addButton(withTitle: "好")
        a.runModal()
    }

    @objc private func logsClicked() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/MacToAndroid")
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }
}
