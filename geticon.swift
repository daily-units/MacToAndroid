// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Waldron
import AppKit

// 用 NSWorkspace 取系统实际解析出的图标——和访达/Dock 走同一条链路
let args = CommandLine.arguments
guard args.count >= 3 else { print("用法: geticon <app路径> <输出png>"); exit(1) }
let icon = NSWorkspace.shared.icon(forFile: args[1])
let size = NSSize(width: 256, height: 256)
let img = NSImage(size: size)
img.lockFocus()
icon.draw(in: NSRect(origin: .zero, size: size))
img.unlockFocus()
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("渲染失败"); exit(1)
}
try png.write(to: URL(fileURLWithPath: args[2]))
print("已写出 \(args[2])")
