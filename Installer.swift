// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Waldron
// 首次运行自装
//
// 为什么需要：.app 本身只是前端，真正干活的是 mta-ctl.sh 与 watcher.sh，
// 加上两个 LaunchAgent。这些原来只由 build.sh 生成，所以别人单独下载 .app
// 只会看到「安装不完整」。现在把脚本打进 Contents/Resources，
// 应用启动时自己铺开——下载来的 .app 也能独立工作。
//
// build.sh 仍然会做同样的事（开发时更直接），两边幂等、互不冲突。

import Foundation

struct Installer {

    static let label = "com.local.mactoandroid"
    static let menuLabel = "com.local.mactoandroid.menubar"
    // uninstall.sh 也要铺出来：只下载了 .app 的人否则没有任何卸载手段，
    // 而拖进废纸篓并不会带走那两个 LaunchAgent——守护进程会继续开机自启
    private static let scripts = ["mta-ctl.sh", "watcher.sh", "uninstall.sh"]

    static var runtimeDir: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/MacToAndroid")
    }
    static var logDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/MacToAndroid")
    }
    private static var agentDir: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
    }

    /// 返回 nil 表示就绪；返回字符串表示无法自装的原因
    @discardableResult
    static func ensure() -> String? {
        let fm = FileManager.default
        for d in [runtimeDir, logDir, agentDir] {
            try? fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }

        var copiedAny = false
        for name in scripts {
            guard let src = Bundle.main.path(forResource: name, ofType: nil) else {
                // 老版本 build.sh 打的包里没有脚本，此时依赖既有安装
                continue
            }
            let dst = (runtimeDir as NSString).appendingPathComponent(name)
            // 逐字节比较而不是比版本号：改脚本后不改版本号也能被更新
            if fm.fileExists(atPath: dst), fm.contentsEqual(atPath: src, andPath: dst) {
                continue
            }
            try? fm.removeItem(atPath: dst)
            do {
                try fm.copyItem(atPath: src, toPath: dst)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
                copiedAny = true
            } catch {
                return "无法写入 \(dst)：\(error.localizedDescription)"
            }
        }

        // 守护进程要用这个路径回头唤起本应用
        let appPath = (runtimeDir as NSString).appendingPathComponent("app-path")
        try? (Bundle.main.bundlePath + "\n").write(toFile: appPath, atomically: true, encoding: .utf8)

        let ctlPath = (runtimeDir as NSString).appendingPathComponent("mta-ctl.sh")
        guard fm.isExecutableFile(atPath: ctlPath) else {
            return "缺少核心控制器：\n\(ctlPath)\n\n请在源码目录执行 ./build.sh。"
        }

        let watcherPath = (runtimeDir as NSString).appendingPathComponent("watcher.sh")
        if fm.isExecutableFile(atPath: watcherPath) {
            // 脚本更新过就必须重启守护进程，否则它还在跑旧代码
            syncAgent(label: label,
                      args: [watcherPath],
                      keepAlive: true,
                      forceReload: copiedAny)
        }
        syncAgent(label: menuLabel,
                  args: ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                  keepAlive: false,
                  forceReload: false)
        return nil
    }

    // MARK: LaunchAgent

    private static func plistBody(label: String, args: [String], keepAlive: Bool) -> String {
        let argXML = args.map { "        <string>\(escape($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(argXML)
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><\(keepAlive ? "true" : "false")/>
            <key>ProcessType</key><string>Background</string>
            <key>ThrottleInterval</key><integer>10</integer>
            <key>LowPriorityIO</key><true/>
            <key>SoftResourceLimits</key>
            <dict>
                <key>NumberOfFiles</key><integer>8192</integer>
            </dict>
            <key>StandardErrorPath</key><string>\(escape(logDir))/\(label).err</string>
        </dict>
        </plist>

        """
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// 只在内容变化或服务未加载时才重载。每次启动都 bootout/bootstrap
    /// 会把守护进程反复重启，正在进行的共享会被打断。
    private static func syncAgent(label: String, args: [String], keepAlive: Bool, forceReload: Bool) {
        let path = (agentDir as NSString).appendingPathComponent("\(label).plist")
        let body = plistBody(label: label, args: args, keepAlive: keepAlive)
        let existing = try? String(contentsOfFile: path, encoding: .utf8)
        // 逐字节比较会把「build.sh 写的那份」永远判成「变了」——它的 plist 里带一段
        // XML 注释、结尾空行也不同。于是每次 build 之后第一次启动 App 都会重载一次
        // 守护进程，打断正在进行的共享。比较前先去掉注释和空白差异。
        let changed = normalized(existing ?? "") != normalized(body)
        if changed {
            try? body.write(toFile: path, atomically: true, encoding: .utf8)
        }
        let loaded = launchctl(["print", "gui/\(getuid())/\(label)"]) == 0
        guard changed || forceReload || !loaded else { return }

        // macOS 13 起，**每次注册后台项目**都会弹一条「App Background Activity —
        // watcher.sh can run in the background」。bootout + bootstrap 等于移除再添加，
        // 于是每次脚本更新都会再弹一条——跟权限无关，在「登录项与扩展」里同意过也不管用。
        // plist 没变、服务还在时（脚本更新走的就是这条）用 kickstart -k 原地重启：
        // 进程换成新的，注册关系不动，不会再触发那条通知。
        if !changed, loaded,
           launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"]) == 0 {
            return
        }

        if loaded {
            _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
            // bootout 是异步的：服务还没退干净时 bootstrap 会以 EIO(5) 失败，
            // 结果是守护进程被卸载掉却没装回来——界面会显示「⚠ 守护进程未运行」，
            // 而用户什么都没做错。等它真的消失再继续，最多 10 秒。
            for _ in 0..<50 {
                if launchctl(["print", "gui/\(getuid())/\(label)"]) != 0 { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        if launchctl(["bootstrap", "gui/\(getuid())", path]) != 0 {
            Thread.sleep(forTimeInterval: 1)
            _ = launchctl(["bootstrap", "gui/\(getuid())", path])
        }
    }

    /// 去掉 XML 注释与空白差异，只比较实质内容
    private static func normalized(_ text: String) -> String {
        var t = text
        while let open = t.range(of: "<!--"),
              let close = t.range(of: "-->", range: open.upperBound..<t.endIndex) {
            t.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return t.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
