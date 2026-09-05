#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Waldron
# 构建 MacToAndroid：一个 App + 守护进程
#
# 需要 swiftc（Xcode 或 Command Line Tools）。生成的 .app 是自包含的：
# mta-ctl.sh 与 watcher.sh 打进 Contents/Resources，应用首次运行会自己铺开
# 并注册 LaunchAgent，所以只拿到 .app 也能用。
#
# 用法:
#   ./build.sh [输出目录]        构建并安装（默认 /Applications），注册 LaunchAgent
#   ./build.sh --no-install [目录]  只构建 .app（默认 ./dist），不铺脚本、不注册 LaunchAgent
#
# --no-install 是给打包/CI 用的：GitHub Actions 的 runner 上 `launchctl bootstrap`
# 会失败，而这个脚本是 set -e，失败会中断整个构建，出不了包。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_SRCS=("$SCRIPT_DIR/MenuBar.swift" "$SCRIPT_DIR/Window.swift" "$SCRIPT_DIR/Installer.swift" "$SCRIPT_DIR/Guide.swift" "$SCRIPT_DIR/Notify.swift")
WATCHER_SRC="$SCRIPT_DIR/watcher.sh"
CTL_SRC="$SCRIPT_DIR/mta-ctl.sh"
UNINSTALL_SRC="$SCRIPT_DIR/uninstall.sh"

VERSION="1.0.0"
LABEL="com.local.mactoandroid"                    # 守护进程
MENU_LABEL="com.local.mactoandroid.menubar"       # 菜单栏应用的登录项
BUNDLE_MENU="com.local.mactoandroid.app"

RUNTIME_DIR="$HOME/Library/Application Support/MacToAndroid"
WATCHER="$RUNTIME_DIR/watcher.sh"
CTL="$RUNTIME_DIR/mta-ctl.sh"
LOG_DIR="$HOME/Library/Logs/MacToAndroid"
AGENT_DIR="$HOME/Library/LaunchAgents"

BUILD_ONLY=0
OUT_ARG=""
while [ $# -gt 0 ]; do
	case "$1" in
		--no-install | --build-only ) BUILD_ONLY=1; shift ;;
		-* ) echo "未知参数: $1" >&2; exit 1 ;;
		* )  OUT_ARG="$1"; shift ;;
	esac
done
if [ -n "$OUT_ARG" ]; then
	OUT_DIR="$OUT_ARG"
elif [ "$BUILD_ONLY" -eq 1 ]; then
	OUT_DIR="$SCRIPT_DIR/dist"          # 只构建时别默认往 /Applications 里装
	mkdir -p "$OUT_DIR"
else
	OUT_DIR="/Applications"
fi
APP="$OUT_DIR/MacToAndroid.app"

ICON_PNG="$SCRIPT_DIR/icon.png"

for f in "$WATCHER_SRC" "$CTL_SRC" "$UNINSTALL_SRC"; do
	[ -f "$f" ] || { echo "缺少文件: $f" >&2; exit 1; }
done
[ -f "$ICON_PNG" ] || { echo "缺少图标底图: $ICON_PNG" >&2; exit 1; }

case "$OUT_DIR" in
	"" | "/" ) echo "输出目录不合法: '$OUT_DIR'" >&2; exit 1 ;;
esac
[ -d "$OUT_DIR" ] || { echo "输出目录不存在: $OUT_DIR" >&2; exit 1; }
[ -w "$OUT_DIR" ] || { echo "没有写入权限: ${OUT_DIR}（可加 sudo 重试）" >&2; exit 1; }

for dep in gnirehtet adb; do
	command -v "$dep" >/dev/null 2>&1 || echo "  ! 未找到 ${dep}，安装后才能正常工作"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 先结束正在运行的旧前端。否则残留进程会占着同一个 bundle id，
# LaunchServices 认为应用已在运行，`open` 只会发一个 reopen 事件，
# 新装的二进制根本不会被启动——表现是「装好了但菜单栏没图标」。
if [ "$BUILD_ONLY" -eq 0 ]; then
	osascript -e "tell application id \"$BUNDLE_MENU\" to quit" >/dev/null 2>&1 || true
	pkill -f "$OUT_DIR/MacToAndroid.app/Contents/MacOS/" 2>/dev/null || true
	sleep 1
fi

# ---------------------------------------------------------------- 图标

IW="$(sips -g pixelWidth  "$ICON_PNG" | awk '/pixelWidth/{print $2}')"
IH="$(sips -g pixelHeight "$ICON_PNG" | awk '/pixelHeight/{print $2}')"
HAS_ALPHA="$(sips -g hasAlpha "$ICON_PNG" | awk '/hasAlpha/{print $2}')"
echo "图标底图: $(basename "$ICON_PNG")  ${IW}x${IH}  alpha=${HAS_ALPHA}"
[ "$IW" = "$IH" ] || echo "  ! 底图不是正方形，图标会被拉伸变形"
[ "$IW" -ge 1024 ] || echo "  ! 底图小于 1024，最大尺寸会被放大而模糊"

# macOS 26 会给「带透明边距的旧格式图标」自动垫一层浅色底板，把图缩小放在中间。
# 要得到系统应用那种满幅观感，图必须满幅不透明，由系统自己切圆角。
ICON_MASTER="$ICON_PNG"
if [ "$HAS_ALPHA" = "yes" ] && [ -f "$SCRIPT_DIR/make-icon.py" ]; then
	if python3 "$SCRIPT_DIR/make-icon.py" "$ICON_PNG" "$TMP/fullbleed.png" --full-bleed; then
		ICON_MASTER="$TMP/fullbleed.png"
	else
		echo "  ! 满幅转换失败，直接使用原图（图标可能被系统垫上浅色底板）"
	fi
fi

ICONSET="$TMP/icon.iconset"
mkdir -p "$ICONSET"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
	set -- $spec
	sips -z "$1" "$1" "$ICON_MASTER" --out "$ICONSET/$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$TMP/applet.icns"

# ---------------------------------------------------------------- 菜单栏应用

MENU_BUILT=0
SWIFT_OK=1
for f in "${SWIFT_SRCS[@]}"; do [ -f "$f" ] || SWIFT_OK=0; done
if [ "$SWIFT_OK" -eq 1 ] && command -v swiftc >/dev/null 2>&1; then
	# 出**通用二进制**：只编本机架构的话，Intel Mac 拿到这个 .app 会直接打不开
	# （报「应用程序不支持此 Mac」），而这类错误发布之后才会被别人发现。
	# 两个架构分别编，再 lipo 合并。非本机架构编不出来只警告——本地开发不该被它挡住，
	# 但发布前 release.sh 会检查产物里两个架构都在。
	NATIVE_ARCH="$(uname -m)"
	SLICES=()
	SWIFT_ERR=""
	for arch in arm64 x86_64; do
		# 用 @main 时必须加 -parse-as-library，否则源文件会被当作顶层脚本
		if swiftc -O -parse-as-library -target "$arch-apple-macos13.0" \
		          -o "$TMP/MacToAndroid.$arch" "${SWIFT_SRCS[@]}" 2>"$TMP/swift.$arch.err"; then
			SLICES+=("$TMP/MacToAndroid.$arch")
		else
			if [ "$arch" = "$NATIVE_ARCH" ]; then
				SWIFT_ERR="$TMP/swift.$arch.err"     # 本机架构都编不过 = 真失败
			else
				echo "  ! $arch 交叉编译失败，产物不含这个架构（Intel Mac 将无法运行）"
			fi
		fi
	done
	if [ ${#SLICES[@]} -gt 0 ] && [ -z "$SWIFT_ERR" ]; then
		if [ ${#SLICES[@]} -gt 1 ]; then
			lipo -create -output "$TMP/MacToAndroid" "${SLICES[@]}"
		else
			cp "${SLICES[0]}" "$TMP/MacToAndroid"
		fi
		echo "二进制架构: $(lipo -archs "$TMP/MacToAndroid")"
		rm -rf "$APP"
		mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
		cp "$TMP/MacToAndroid" "$APP/Contents/MacOS/MacToAndroid"
		cp "$TMP/applet.icns" "$APP/Contents/Resources/applet.icns"
		# 打进包里：应用首次运行会把它们铺到 ~/Library/Application Support 并
		# 注册 LaunchAgent。这样别人单独拿到 .app 也能用，不必先跑 build.sh。
		# 卸载脚本也要打进包：只拿到 .app 的人否则根本没有卸载手段，
		# 而这个 App 装了两个 LaunchAgent——把 .app 拖进废纸篓，守护进程还会继续跑
		cp "$CTL_SRC" "$WATCHER_SRC" "$UNINSTALL_SRC" "$APP/Contents/Resources/"
		# 分发出去的 .app 要自带许可证原文：Apache-2.0 第 4(a) 条要求随作品附上一份 License
		for lic in LICENSE NOTICE; do
			if [ -f "$SCRIPT_DIR/$lic" ]; then cp "$SCRIPT_DIR/$lic" "$APP/Contents/Resources/$lic"; fi
		done
		chmod +x "$APP/Contents/Resources/mta-ctl.sh" "$APP/Contents/Resources/watcher.sh" \
		         "$APP/Contents/Resources/uninstall.sh"
		cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MacToAndroid</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_MENU</string>
    <key>CFBundleName</key><string>MacToAndroid</string>
    <key>CFBundleDisplayName</key><string>MacToAndroid</string>
    <key>CFBundleIconFile</key><string>applet</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <!-- 只在菜单栏出现，不占 Dock、不进 ⌘Tab -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
		codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true
		touch "$APP"
		if [ "$BUILD_ONLY" -eq 1 ]; then
			echo "已生成 App: $APP"
		else
			echo "已安装 App（菜单栏版）: $APP"
		fi
		MENU_BUILT=1
	else
		echo "Swift 编译失败:" >&2
		sed 's/^/  /' "${SWIFT_ERR:-$TMP/swift.$NATIVE_ARCH.err}" >&2
		exit 1
	fi
else
	echo "需要 swiftc 才能构建。请安装 Xcode 或 Command Line Tools：" >&2
	echo "  xcode-select --install" >&2
	exit 1
fi

# ---------------------------------------------------------------- 核心与守护进程

if [ "$BUILD_ONLY" -eq 1 ]; then
	echo
	echo "只构建模式：已生成 ${APP}（未铺开脚本、未注册 LaunchAgent）"
	exit 0
fi

# 运行时目录只在真的要安装时才建。放在上面那个提前退出之前的话，
# --no-install（打包 / CI 用）也会在机器上留下三个空目录，
# 与它「不铺脚本、不注册 LaunchAgent」的承诺不符。
mkdir -p "$RUNTIME_DIR" "$LOG_DIR" "$AGENT_DIR"

cp "$WATCHER_SRC" "$WATCHER"
cp "$CTL_SRC" "$CTL"
cp "$UNINSTALL_SRC" "$RUNTIME_DIR/uninstall.sh"
chmod +x "$WATCHER" "$CTL" "$RUNTIME_DIR/uninstall.sh"

# 守护进程发现陌生设备时用这个绝对路径唤起前端。
# 优先菜单栏版：它常驻，收到的是 reopen 事件，响应即时。
printf '%s\n' "$APP" > "$RUNTIME_DIR/app-path"

write_agent() {
	local label="$1" plist="$AGENT_DIR/$1.plist"
	shift
	local tmp="$TMP/$label.plist"
	cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$label</string>
    <key>ProgramArguments</key>
    <array>
$(for a in "$@"; do printf '        <string>%s</string>\n' "$a"; done)
    </array>
    <key>RunAtLoad</key><true/>
$KEEPALIVE_XML
    <key>ProcessType</key><string>Background</string>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>LowPriorityIO</key><true/>
    <!-- launchd 会话默认 maxfiles 软上限只有 256，relay 每个连接占一个套接字，
         撑爆后会丢包并且不自行恢复。这里让守护进程及其子进程继承更高的上限。 -->
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key><integer>8192</integer>
    </dict>
    <key>StandardErrorPath</key><string>$LOG_DIR/$label.err</string>
</dict>
</plist>
PLIST
	plutil -lint "$tmp" >/dev/null

	local same=0
	[ -f "$plist" ] && cmp -s "$tmp" "$plist" && same=1
	cp "$tmp" "$plist"

	# macOS 13 起，**每次注册后台项目**都会给用户弹一条
	# 「App Background Activity —— watcher.sh can run in the background」。
	# bootout + bootstrap 等于「移除再添加」，于是每跑一次 build.sh 就弹一条，
	# 反复调试时会攒一屏。跟权限无关——在「登录项与扩展」里点过同意也不会让它消失。
	#
	# plist 内容没变、服务还在时用 kickstart -k 原地重启：进程会换成新的
	# （脚本更新需要这个），但注册关系不动，所以不会再触发那条通知。
	if [ "$same" -eq 1 ] && launchctl print "gui/$UID/$label" >/dev/null 2>&1; then
		if launchctl kickstart -k "gui/$UID/$label" >/dev/null 2>&1; then
			echo "已原地重启: ${label}（未重新注册，不会再弹后台项目通知）"
			return 0
		fi
		# kickstart 不可用就退回重装
	fi

	launchctl bootout "gui/$UID/$label" 2>/dev/null || true
	# bootout 是**异步**的：服务还在退出时 bootstrap 会以 `Bootstrap failed: 5:
	# Input/output error` 失败。而这个脚本是 set -e —— 结果就是「App 装好了、
	# 守护进程却被卸载掉没再装回来」，而且后面的登录项也不会注册。踩过一次。
	local i
	for i in $(seq 1 50); do          # 最多等 10 秒
		launchctl print "gui/$UID/$label" >/dev/null 2>&1 || break
		sleep 0.2
	done
	if ! launchctl bootstrap "gui/$UID" "$plist" 2>/dev/null; then
		sleep 1
		launchctl bootstrap "gui/$UID" "$plist"
	fi
	echo "已注册: $label"
}

# 守护进程要一直活着
KEEPALIVE_XML='    <key>KeepAlive</key><true/>'
write_agent "$LABEL" "$WATCHER"

# 菜单栏应用只在登录时启动。不能用 KeepAlive——否则用户从菜单里「退出」会被立刻拉回来。
if [ "$MENU_BUILT" -eq 1 ]; then
	KEEPALIVE_XML='    <key>KeepAlive</key><false/>'
	write_agent "$MENU_LABEL" "/usr/bin/open" "-a" "$APP"
fi

echo
echo "完成。菜单栏应该已出现图标，菜单里「打开窗口」可展开完整界面。"
