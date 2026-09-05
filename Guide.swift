// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Waldron
// 条件不满足时的引导层
//
// 为什么需要单独一层：reconcile 会**故意**吞掉 client_start 的失败——自动路径必须
// 静默，插线充电不该被弹窗打扰。代价是 `allow` 也返回 0，调用方无从得知失败，
// 界面只能显示「已允许·待启动」，用户完全不知道卡在哪。
//
// 所以显式路径（用户主动点「共享」）必须自己先问 `ctl why`，把阻塞原因逐个解决掉。
//
// 全流程异步：安装 APK 可能要几十秒，同步跑会把菜单栏卡成转圈。

import AppKit

/// `ctl why` 回显的原因解析成具体问题。
/// 判据是中文子串——`mta-ctl.sh` 里的文案是稳定的协议，改文案要同步改这里。
enum PreflightIssue {
    case ok
    case noGnirehtet
    case noAdb
    case offline
    case emulator
    case clientMissing
    case versionMismatch(String)
    case hasOwnNetwork
    case needVpnConsent
    case secureSettings
    case autoOff
    case other(String)

    static func parse(_ raw: String) -> PreflightIssue {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.isEmpty { return .ok }
        if r.contains("gnirehtet 未安装") { return .noGnirehtet }
        if r.contains("adb 未安装") { return .noAdb }
        if r.contains("设备不在线") { return .offline }
        if r.contains("模拟器") { return .emulator }
        if r.contains("手机端未安装客户端") { return .clientMissing }
        if r.contains("版本不一致") { return .versionMismatch(r) }
        if r.contains("手机已有自己的网络") { return .hasOwnNetwork }
        if r.contains("VPN 连接请求") { return .needVpnConsent }
        if r.contains("USB 调试（安全设置）") { return .secureSettings }
        if r.contains("自动模式已关闭") { return .autoOff }
        return .other(r)
    }
}

enum Guide {

    /// 用户主动要求共享一台设备。会先解决阻塞原因，再启动并确认真的连上了。
    static func share(serial: String, label: String, refresh: @escaping () -> Void) {
        step(serial: serial, label: label, round: 0, refresh: refresh)
    }

    /// 上限 4 轮：每解决一个问题就重查一次，避免异常情况下无限弹窗
    private static let maxRounds = 4

    private static func step(serial: String, label: String, round: Int,
                            refresh: @escaping () -> Void) {
        guard round < maxRounds else {
            alert("仍无法共享", "已尝试 \(maxRounds) 次仍未就绪。可在「环境自检…」里查看详情，或查看日志。", .warning)
            refresh()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let reason = Ctl.run(["why", serial]) ?? ""
            DispatchQueue.main.async {
                handle(PreflightIssue.parse(reason), serial: serial, label: label,
                       round: round, refresh: refresh)
            }
        }
    }

    private static func handle(_ issue: PreflightIssue, serial: String, label: String,
                               round: Int, refresh: @escaping () -> Void) {
        switch issue {
        case .ok:
            allowAndVerify(serial: serial, label: label, round: round, refresh: refresh)

        case .clientMissing:
            askInstall(serial: serial, label: label, round: round, refresh: refresh)

        case .versionMismatch(let detail):
            let a = NSAlert()
            a.messageText = "两端版本不一致"
            a.informativeText = "\(label)\n\(detail)\n\n协议可能不兼容，表现为能连上但不通。建议重新安装手机端客户端。"
            a.alertStyle = .warning
            a.addButton(withTitle: "重新安装")
            a.addButton(withTitle: "取消")
            activate()
            if a.runModal() == .alertFirstButtonReturn {
                runInstall(serial: serial, label: label, round: round, refresh: refresh)
            } else {
                refresh()
            }

        case .noGnirehtet:
            showBrew("gnirehtet", cmd: "brew install gnirehtet")
            refresh()

        case .noAdb:
            showBrew("adb", cmd: "brew install --cask android-platform-tools")
            refresh()

        case .offline:
            alert("设备不在线", """
            \(label)
            \(serial)

            请检查：
            • 数据线已连接，且是数据线不是纯充电线
            • 手机「开发者选项 → USB 调试」已开启
            • 手机上弹出的「允许 USB 调试」已点允许

            排查命令：adb devices
            """, .warning)
            refresh()

        case .emulator:
            alert("这是模拟器", "\(label)\n\n模拟器自身已有网络，不需要也无法通过 USB 反向共享。", .informational)
            refresh()

        case .needVpnConsent:
            // 用户在手机上删掉/撤销了保存的 VPN 配置之后就是这个状态：
            // preflight 全过（客户端装着、版本一致、设备在线），但 VpnService 起不来，
            // 因为 Android 要在**手机屏幕上**重新授权一次。
            // 以前这里 why 输出为空，界面只显示「已允许·待启动」，用户只能靠
            // 「停止共享 → 开始共享」这套动作误打误撞地把授权框逼出来。
            let a = NSAlert()
            a.messageText = "请在手机上允许 VPN 连接"
            a.informativeText = """
            \(label)

            手机端客户端已经拉起，但 VPN 没有建立——Android 需要在手机屏幕上
            确认一次「连接请求 / Connection request」。如果之前在手机上删掉了
            保存的 VPN 配置，就一定会再问一次。

            解锁手机、点「确定」，然后回到这里点「已允许，重试」。
            """
            a.alertStyle = .informational
            a.addButton(withTitle: "已允许，重试")
            a.addButton(withTitle: "取消")
            activate()
            if a.runModal() == .alertFirstButtonReturn {
                allowAndVerify(serial: serial, label: label, round: round, refresh: refresh)
            } else {
                refresh()
            }

        case .autoOff:
            // 自动模式是总开关：关着时 reconcile 第一件事就是 stop_all 然后返回。
            // 以前这里查不出来，于是「点了开始共享 → 按钮翻成停止共享 → 手机上没有 VPN」，
            // 而引导层还会把原因猜成「请在手机上允许 VPN 连接」。
            let a = NSAlert()
            a.messageText = "自动模式当前是关闭的"
            a.informativeText = """
            \(label)

            自动模式是总开关，关着的时候不会给任何设备共享网络——所以即使这台设备
            已经在允许列表里，手机上也不会出现 VPN。

            开启之后它会立刻开始共享，之后插上线也会自动接管。
            """
            a.alertStyle = .informational
            a.addButton(withTitle: "开启自动模式并共享")
            a.addButton(withTitle: "取消")
            activate()
            guard a.runModal() == .alertFirstButtonReturn else { refresh(); return }
            DispatchQueue.global(qos: .userInitiated).async {
                _ = Ctl.run(["auto", "on"], timeout: 90)
                DispatchQueue.main.async {
                    step(serial: serial, label: label, round: round + 1, refresh: refresh)
                }
            }

        case .secureSettings:
            // `gnirehtet start` 实际跑的是 adb shell am start，小米在
            // 「USB 调试（安全设置）」关闭时会拒掉它，报 WRITE_SECURE_SETTINGS。
            showSecureSettings(serial: serial,
                               tail: Ctl.run(["last-start", serial]) ?? "")
            refresh()

        case .hasOwnNetwork:
            alert("手机已有自己的网络", """
            \(label)

            你启用了「仅在手机无网络时接管」（存在 ~/.config/mactoandroid/only-when-offline），
            所以本次不接管。删掉那个文件即可恢复无条件接管。
            """, .informational)
            refresh()

        case .other(let r):
            alert("无法共享", "\(label)\n\n\(r)", .warning)
            refresh()
        }
    }

    // MARK: 安装手机端客户端

    private static func askInstall(serial: String, label: String, round: Int,
                                   refresh: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "手机上还没有安装客户端"
        a.informativeText = """
        \(label)
        \(serial)

        这个客户端负责在手机端建立 VPN 隧道，把流量转给 Mac。它没有桌面图标，由本应用通过 adb 拉起。
        """
        a.alertStyle = .informational
        a.addButton(withTitle: "立即安装")
        a.addButton(withTitle: "推送到手机手动装")
        a.addButton(withTitle: "取消")
        activate()
        switch a.runModal() {
        case .alertFirstButtonReturn:
            runInstall(serial: serial, label: label, round: round, refresh: refresh)
        case .alertSecondButtonReturn:
            runPush(serial: serial, refresh: refresh)
        default:
            refresh()
        }
    }

    private static func runInstall(serial: String, label: String, round: Int,
                                   refresh: @escaping () -> Void) {
        // 安装可能要几十秒，放后台并给足超时；默认 8 秒远远不够
        DispatchQueue.global(qos: .userInitiated).async {
            let out = (Ctl.run(["install-client", serial], timeout: 180) ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if out == "ok" {
                    step(serial: serial, label: label, round: round + 1, refresh: refresh)
                    return
                }
                if out == "restricted" || out.contains("restricted") {
                    showRestricted(serial: serial, refresh: refresh)
                    return
                }
                if out == "incompatible" {
                    showIncompatible(serial: serial, label: label, round: round, refresh: refresh)
                    return
                }
                // 其他原因失败**不能只报一句 adb 的英文输出然后关掉**——用户拿着
                // "INSTALL_FAILED_..." 无从下手。推送到手机手动装是通用退路
                // （走普通安装渠道），所以要把这条路摆在按钮上，而不是让人自己猜。
                showInstallFailed(serial: serial, label: label, out: out, refresh: refresh)
            }
        }
    }

    /// 自动安装因为「其他原因」失败时的出口。
    /// 原则：每一步失败都要给出下一步，不能把用户留在一句报错上。
    private static func showInstallFailed(serial: String, label: String, out: String,
                                          refresh: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "自动安装没成功"
        a.informativeText = """
        \(label)

        adb 的返回：
        \(out.isEmpty ? "（没有可用信息，请查看日志）" : out)

        可以改用「推送到手机」：把安装包放进手机的「下载」，在手机上点一下装。
        这条路走的是普通安装渠道，不受 adb 安装限制影响。
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "推送到手机手动装")
        a.addButton(withTitle: "打开开发者选项")
        a.addButton(withTitle: "取消")
        activate()
        switch a.runModal() {
        case .alertFirstButtonReturn:
            runPush(serial: serial, refresh: refresh)
        case .alertSecondButtonReturn:
            _ = Ctl.run(["open-dev-options", serial])
            refresh()
        default:
            refresh()
        }
    }

    /// 手机上已有同包名、但签名不同的版本（从别处装过 gnirehtet）。
    /// 这种情况**推送手动装也没用**——手机会直接报「应用未安装」，
    /// 所以必须单独一条路径：先卸掉旧的，再重试。
    private static func showIncompatible(serial: String, label: String, round: Int,
                                         refresh: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "手机上已有一个签名不同的同名应用"
        a.informativeText = """
        \(label)

        手机上装过来源不同的 gnirehtet 客户端，Android 不允许用另一个签名覆盖安装
        （报 INSTALL_FAILED_UPDATE_INCOMPATIBLE）。这种情况把安装包推到手机上手动点
        也会失败——必须先把旧的卸掉。

        卸载只影响这个客户端，不动别的东西。
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "卸载旧版并重新安装")
        a.addButton(withTitle: "取消")
        activate()
        guard a.runModal() == .alertFirstButtonReturn else { refresh(); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let r = (Ctl.run(["uninstall-client", serial], timeout: 120) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                guard r == "ok" else {
                    alert("卸载失败", "\(label)\n\n\(r.isEmpty ? "没有返回可用信息，请查看日志。" : r)", .critical)
                    refresh()
                    return
                }
                runInstall(serial: serial, label: label, round: round + 1, refresh: refresh)
            }
        }
    }

    /// 连推送都失败时的最后一步：把安装包在访达里指给用户，让他用别的方式传过去。
    /// 到这一步还什么都不说，用户就只能放弃了。
    private static func revealAPK() {
        let path = (Ctl.run(["apk-path"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            alert("找不到安装包", "gnirehtet 的 APK 不在预期位置，请检查 gnirehtet 是否装好（brew install gnirehtet）。", .warning)
            return
        }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    /// 小米 / HyperOS 在「USB 安装」关闭时会拦掉**一切** adb 安装路径：
    /// 实测 `adb install`、`pm install`（含从 /data/local/tmp）、会话式
    /// install-create/write/commit 全部返回 INSTALL_FAILED_USER_RESTRICTED，没有绕法。
    ///
    /// 所以只能让用户在手机上手动点。但「告诉用户去找文件」是很糟的体验——
    /// 这里直接把 APK 推过去并打开手机的「下载」界面，用户看到的就是那个文件本身。
    private static func showRestricted(serial: String, refresh: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pushed = (Ctl.run(["push-client", serial], timeout: 120) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines) == "ok"
            if pushed { _ = Ctl.run(["open-downloads", serial]) }

            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = "手机拦住了自动安装"
                if pushed {
                    a.informativeText = """
                    小米 / HyperOS 在「USB 安装」关闭时会拒绝一切通过 adb 的安装，无法绕开。

                    已把安装包推送到手机，并打开了手机上的「下载」界面 ——                     直接点其中的 gnirehtet.apk 安装即可，装好后回来点「开始共享」。

                    想让以后能自动安装：开发者选项 → 打开「USB 安装」（需登录小米账号）。
                    """
                    a.alertStyle = .informational
                    a.addButton(withTitle: "好")
                    a.addButton(withTitle: "打开开发者选项")
                } else {
                    a.informativeText = """
                    小米 / HyperOS 在「USB 安装」关闭时会拒绝一切通过 adb 的安装，无法绕开。

                    推送安装包也失败了。请在手机上打开：
                        开发者选项 → USB 安装
                    然后回来重试。
                    """
                    a.alertStyle = .warning
                    a.addButton(withTitle: "打开开发者选项")
                    a.addButton(withTitle: "取消")
                }
                activate()
                let r = a.runModal()
                let wantDevOptions = pushed
                    ? (r == .alertSecondButtonReturn)
                    : (r == .alertFirstButtonReturn)
                if wantDevOptions { _ = Ctl.run(["open-dev-options", serial]) }
                refresh()
            }
        }
    }

    private static func runPush(serial: String, refresh: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let out = (Ctl.run(["push-client", serial], timeout: 120) ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if out == "ok" {
                    // 顺手打开「下载」界面，省掉用户自己找文件
                    _ = Ctl.run(["open-downloads", serial])
                    alert("APK 已推送到手机", """
                    已打开手机上的「下载」界面，直接点其中的 gnirehtet.apk 安装即可。
                    这走的是普通安装渠道，不受「USB 安装」限制。

                    装好后再点一次「开始共享」。
                    """, .informational)
                } else {
                    let a = NSAlert()
                    a.messageText = "推送失败"
                    a.informativeText = """
                    \(out.isEmpty ? "adb push 没有返回可用信息。" : out)

                    最后一条路：把安装包用别的方式传到手机上（AirDrop、微信传输、
                    或者把手机切到「文件传输 / MTP」模式直接拷），然后在手机上点它安装。
                    """
                    a.alertStyle = .critical
                    a.addButton(withTitle: "在访达中显示安装包")
                    a.addButton(withTitle: "取消")
                    activate()
                    if a.runModal() == .alertFirstButtonReturn { revealAPK() }
                }
                refresh()
            }
        }
    }

    // MARK: 启动并确认

    /// allow 之后必须确认真的进入了 shared。只写策略不代表连上了——
    /// 典型失败是小米的「USB 调试（安全设置）」没开，导致 am start 被拒。
    private static func allowAndVerify(serial: String, label: String, round: Int,
                                       refresh: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard Ctl.run(["allow", serial], timeout: 30) != nil else {
                DispatchQueue.main.async {
                    alert("操作未完成", "控制器执行 allow 失败。常见原因是另一个操作正在进行（守护进程正在对账），稍等几秒再试。", .warning)
                    refresh()
                }
                return
            }

            // 轮询等它真的连上，最多 8 秒
            var shared = false
            for _ in 0..<16 {
                Thread.sleep(forTimeInterval: 0.5)
                if loadDevices().first(where: { $0.serial == serial })?.state == "shared" {
                    shared = true
                    break
                }
            }

            // WRITE_SECURE_SETTINGS 只会出现在 `gnirehtet start` 的回显里
            // （它内部跑的是 adb shell am start）。relay.log 是 relay 进程自己的日志，
            // 永远不会有这个串——早期版本在那里 grep，于是这条分支从来没命中过。
            let startOut = shared ? "" : (Ctl.run(["last-start", serial]) ?? "")
            let tail = shared ? "" : tailRelayLog(4000)
            // **先问 why 再猜**：allow 之后仍然没起来时，preflight 往往已经知道原因
            // （自动模式关着、客户端被卸了、版本不一致……）。早期版本直接跳到
            // 「VPN 授权没点」，于是自动模式关闭这种情况会得到一个完全错误的诊断。
            let why = shared ? "" : (Ctl.run(["why", serial]) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                if shared {
                    refresh()
                    return
                }
                if !why.isEmpty {
                    handle(PreflightIssue.parse(why), serial: serial, label: label,
                           round: round + 1, refresh: refresh)
                    return
                }
                if startOut.contains("WRITE_SECURE_SETTINGS")
                    || startOut.contains("Permission Denial")
                    || startOut.contains("SecurityException") {
                    showSecureSettings(serial: serial, tail: startOut)
                } else if (Ctl.run(["client-running", serial]) ?? "").contains("no") {
                    // 新设备第一次运行时 Android 会弹 VPN「连接请求」授权框，
                    // 不点允许就永远连不上。这是新设备最常见的卡点，
                    // 而界面原来只会显示「共享中」，用户完全不知道要去看手机
                    alert("请在手机上允许 VPN 连接", """
                    \(label)

                    客户端已启动但没有建立 VPN。第一次使用时 Android 会弹出
                    「连接请求 / Connection request」授权框，需要在**手机屏幕上**点「确定」。

                    去手机上看一眼，允许之后回来再点一次即可。
                    """, .informational)
                } else {
                    // why 为空才会走到这里（上面已经处理过有原因的情况）
                    alert("已允许，但没有连上", """
                    \(label)

                    日志末尾：

                    \(lastLines(tail, 3))
                    """, .warning)
                }
                refresh()
            }
        }
    }

    private static func showSecureSettings(serial: String, tail: String) {
        let a = NSAlert()
        a.messageText = "无法拉起手机端客户端"
        a.informativeText = """
        relay 已启动，但缺少 WRITE_SECURE_SETTINGS 权限。

        请在手机上打开：
            开发者选项 → USB 调试（安全设置）

        该开关允许 adb 启动应用与修改权限，同样需要已登录小米账号。系统更新后可能被重置。

        启动回显：
        \(lastLines(tail, 3))
        """
        a.alertStyle = .warning
        a.addButton(withTitle: "打开开发者选项")
        a.addButton(withTitle: "好")
        activate()
        if a.runModal() == .alertFirstButtonReturn {
            _ = Ctl.run(["open-dev-options", serial])
        }
    }

    // MARK: 工具

    private static func showBrew(_ name: String, cmd: String) {
        let a = NSAlert()
        a.messageText = "缺少 \(name)"
        a.informativeText = "请在「终端」执行：\n\n\(cmd)\n\n装好后重新打开本应用。"
        a.alertStyle = .warning
        a.addButton(withTitle: "复制命令")
        a.addButton(withTitle: "好")
        activate()
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }

    private static func alert(_ title: String, _ message: String, _ style: NSAlert.Style) {
        activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = style
        a.addButton(withTitle: "好")
        a.runModal()
    }

    /// 菜单栏应用是 LSUIElement，不激活的话弹窗会出现在其他应用后面
    private static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func tailRelayLog(_ bytes: Int) -> String {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/MacToAndroid/relay.log")
        guard let h = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func lastLines(_ text: String, _ n: Int) -> String {
        text.split(separator: "\n").suffix(n).joined(separator: "\n")
    }
}
