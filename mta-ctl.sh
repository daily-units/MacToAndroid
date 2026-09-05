#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Waldron
# MacToAndroid 核心控制器 —— 守护进程与 App 共用，避免策略逻辑写两份
#
# 架构：一个 gnirehtet relay 常驻，每台设备用 gnirehtet start/stop 独立启停。
#       relay 能同时服务多个 client，所以支持同时给多台设备共享。
#
# 设备策略（配置在 ~/.config/mactoandroid/）
#   allow/<serial>   允许共享。文件内容是型号名，便于 UI 在设备离线时显示可读名称
#   deny/<serial>    拒绝，不再询问
#   两者都没有       陌生设备，交给 App 询问用户
#
# 只有 USB 连接的真机参与策略。模拟器与无线调试设备本身就有网络，直接忽略。
#
# 子命令见底部 usage。所有输出都设计成易解析的纯文本（key=value 或 tab 分隔）。

set -u

MTA_VERSION="1.0.0"

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------- 环境

# LaunchAgent 的 PATH 很干净，需要自己补上包管理器的位置。
# 不写死 /opt/homebrew：Intel Mac 的 Homebrew 在 /usr/local，MacPorts 在 /opt/local。
# 顺序重要：包管理器目录优先，用户可写目录放最后。
# 循环是逐个「前置」，所以这里要倒着列。
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
for p in "$HOME/.local/bin" /opt/local/bin /usr/local/bin /opt/homebrew/bin; do
	[ -d "$p" ] && PATH="$p:$PATH"
done
export PATH

CONF_DIR="$HOME/.config/mactoandroid"
FLAG="$CONF_DIR/enabled"
ALLOW_DIR="$CONF_DIR/allow"
DENY_DIR="$CONF_DIR/deny"
PENDING="$CONF_DIR/pending-ask"
OFFLINE_ONLY="$CONF_DIR/only-when-offline"

# 易变状态放每用户的临时目录（独立、开机清空），**不放 /tmp**：
# /tmp 所有用户可写，固定文件名会被抢先创建成符号链接。
#
# 但不能写成 ${TMPDIR:-/tmp}：SSH、cron 这类环境里 TMPDIR 可能是空的，那个兜底
# 恰好把状态放回了 /tmp——而且和守护进程用的是**两份不同的状态**（锁不共享，
# 于是可能起第二个 relay，两个 relay 抢同一个端口和设备）。
# getconf DARWIN_USER_TEMP_DIR 返回的就是 launchd 给的那个每用户目录，与环境变量无关。
state_root() {
	local d
	d="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
	case "$d" in /*) printf '%s' "${d%/}"; return 0 ;; esac
	case "${TMPDIR:-}" in /*) printf '%s' "${TMPDIR%/}"; return 0 ;; esac
	return 1
}
STATE_ROOT="$(state_root)" || {
	echo "拿不到每用户临时目录（getconf DARWIN_USER_TEMP_DIR 与 \$TMPDIR 都不可用）" >&2
	exit 1
}
STATE_DIR="$STATE_ROOT/MacToAndroid"
ACTIVE="$STATE_DIR/active"          # 我们已启动 client 的设备
ASKED="$STATE_DIR/asked"            # 本次开机已问过的设备，避免反复弹窗
DNS_APPLIED="$STATE_DIR/dns"        # 最近一次下发给手机的 DNS
DNS_CANDIDATE="$STATE_DIR/dns.cand" # 观察中的新 DNS，连续两次一致才下发
IGN_SIG="$STATE_DIR/ignored.sig"    # 上次记录的被忽略设备清单，避免日志刷屏
PORT_FILE="$STATE_DIR/port"         # 当前生效的端口
LOCK="$STATE_DIR/lock"
# 状态变化戳。App 用 kqueue 盯着这个文件，一变就立刻刷新界面，不必等它自己轮询。
# 必须**原地重写**（截断+写），inode 不能变：kqueue 盯的是 inode，
# 而且盯目录只在「增删条目」时触发、改文件内容不算，所以只能盯文件本身。
STAMP="$STATE_DIR/changed"
RELAY_PID_FILE="$STATE_DIR/relay.pid"   # 自己启动的 relay，避免每次都跑 lsof

LOG_DIR="$HOME/Library/Logs/MacToAndroid"
CTL_LOG="$LOG_DIR/ctl.log"
RELAY_LOG="$LOG_DIR/relay.log"
LOG_MAX=200000
LOG_KEEP=100000

PKG="com.genymobile.gnirehtet"

# 31416 是 gnirehtet 的默认端口，但它不是注册端口，任何程序都可能占用。
# 被占时自动在 PORT_BASE..PORT_BASE+PORT_TRIES-1 里找一个空闲的，
# 并把选中的端口持久化——relay 与各设备的 client 必须用同一个端口，
# 而它们由不同次调用启动，所以不能只存在内存里。
PORT_BASE=31416
PORT_TRIES=10

# relay 的文件描述符上限。launchd 给的软上限只有 256，远不够一台设备的并发连接。
FD_LIMIT=8192

# 设备短暂消失的宽限期（秒）。USB 接触不良会造成 1~3 秒的闪断，
# 若一消失就拆隧道，每次抖动都要用 gnirehtet stop+start 重建一遍（约 2 秒），
# 反而把抖动放大成持续的空转。宽限期内先按兵不动。
MISSING_GRACE=8

umask 077
mkdir -p "$CONF_DIR" "$ALLOW_DIR" "$DENY_DIR" "$LOG_DIR" 2>/dev/null
mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null
: >> "$ACTIVE" 2>/dev/null || true
: >> "$ASKED" 2>/dev/null || true

log() { echo "$(date '+%F %T') [ctl] $*" >> "$CTL_LOG" 2>/dev/null || true; }

# 通知界面「状态可能变了」。只在真的发生转变的地方调用，不要在心跳这种
# 什么都没变的路径上调用——否则等于把 App 的轮询频率翻上去。
stamp() { date +%s > "$STAMP" 2>/dev/null || true; }

# 生效端口。取持久化的值，没有则用默认；越界的值一律丢弃。
read_port() {
	local p
	p="$(cat "$PORT_FILE" 2>/dev/null || true)"
	case "$p" in
		"" | *[!0-9]* ) echo "$PORT_BASE"; return 0 ;;
	esac
	if [ "$p" -lt "$PORT_BASE" ] || [ "$p" -ge $((PORT_BASE + PORT_TRIES)) ]; then
		echo "$PORT_BASE"; return 0
	fi
	echo "$p"
}
PORT="$(read_port)"

# 轮转必须**原地截断**，不能 mv 覆盖。
# relay 是以 `>> "$RELAY_LOG"` 启动的常驻进程，它的 fd 指向 inode 而不是路径：
# mv 之后它会继续往被 unlink 的旧 inode 里写，relay.log 从此冻结在轮转那一刻，
# 而 fd_exhausted() 读的是新文件 —— 于是「界面绿灯、手机 VPN 亮着、一个包都过不去」
# 这个本来靠 relay.log 才能发现的静默故障，重新变回完全静默的。
trim_log() {
	local f sz
	# *.err 是 plist 里 StandardErrorPath 指向的文件，由 launchd 持有 fd。
	# 平时是 0 字节，但只要出现「每 20 秒报一次错」这类循环就会无限长，没人管。
	# 它们同样必须原地截断——launchd 那个 fd 指向 inode。
	for f in "$CTL_LOG" "$RELAY_LOG" "$LOG_DIR"/*.err; do
		sz="$(stat -f%z "$f" 2>/dev/null || echo 0)"
		[ "$sz" -le "$LOG_MAX" ] && continue
		tail -c "$LOG_KEEP" "$f" > "$f.tmp" 2>/dev/null || continue
		# cat 覆盖而不是 mv：inode 不变，写入者的 fd 仍然有效（O_APPEND 会写到新的末尾）
		cat "$f.tmp" > "$f" 2>/dev/null
		rm -f "$f.tmp"
	done
}

die() { echo "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 互斥锁

# App 和守护进程会并发调用本脚本（用户点按钮的同时设备事件到达），
# 不加锁会出现重复启动 relay、active 文件互相覆盖等问题。
# 用 mkdir 的原子性实现，并检测持有者是否已死，避免崩溃后永久死锁。
acquire_lock() {
	local i holder empty=0
	for i in $(seq 1 150); do          # 最多等 30 秒
		if mkdir "$LOCK" 2>/dev/null; then
			echo $$ > "$LOCK/pid" 2>/dev/null
			trap 'release_lock' EXIT INT TERM
			return 0
		fi
		holder="$(cat "$LOCK/pid" 2>/dev/null || true)"
		if [ -z "$holder" ]; then
			# 「mkdir 成功了但还没写 pid」的窗口只有几毫秒。连续 2 秒都读不到 pid，
			# 说明持有者在写 pid 之前就死了——这个锁不会有人来释放，
			# 干等满 30 秒只会把这次操作白白丢掉
			empty=$((empty + 1))
			if [ "$empty" -gt 10 ]; then
				log "清理没有持有者的锁"
				rm -rf "$LOCK"; empty=0
				continue
			fi
		else
			empty=0
			if ! kill -0 "$holder" 2>/dev/null; then
				log "清理僵死的锁（持有者 $holder 已不存在）"
				rm -rf "$LOCK"
				continue
			fi
		fi
		sleep 0.2
	done
	log "获取锁超时，放弃本次操作"
	return 1
}

release_lock() { rm -rf "$LOCK" 2>/dev/null || true; }

# **不要给只读子命令装 TERM trap。** 界面的 watchdog 超时靠的就是「TERM 直接杀死 ctl」：
# bash 在等前台子进程（adb）时收到 TERM，如果**有** trap，会把它压到子进程结束之后才处理
# ——实测有 trap 的脚本 TERM 后 4.6 秒仍存活，没有 trap 的 0.0 秒就死了。
# 装上 trap 会把「挂住的 adb 在 2 秒超时下 2.17 秒返回」这个机制直接废掉，
# 界面反而会被拖到 adb 自己结束为止。代价是被杀时 adb 子进程会变成孤儿（它会自己跑完），
# 以及锁目录留在原地——后者由 acquire_lock 的「持有者已死」检测回收。
#
# 改状态的子命令由 acquire_lock 装 `trap release_lock EXIT INT TERM`，
# 它们因此**不可被及时打断**——但那是对的：锁必须持有到 adb 真的结束，
# 否则对账会和安装并发。所以这两类子命令的行为差异是有意的。

unmark_asked() {
	grep -vxF -- "$1" "$ASKED" 2>/dev/null > "$ASKED.tmp" || true
	mv "$ASKED.tmp" "$ASKED" 2>/dev/null || true
}

mark_asked() {
	grep -qxF -- "$1" "$ASKED" 2>/dev/null || echo "$1" >> "$ASKED"
}

# ---------------------------------------------------------------- 输入校验

# 序列号会被拼进文件路径，必须校验，否则 '../../x' 之类能写到预期之外的位置
valid_serial() {
	local s="${1:-}"
	[ -n "$s" ] || return 1
	[ "${#s}" -le 128 ] || return 1
	case "$s" in
		. | .. | */* | *'\'* ) return 1 ;;
		# 以 - 开头的会被后面的 `grep -qxF -- "$s"` 和 `gnirehtet start "$s"` 当成选项。
		# adb 的序列号不会长这样，直接拒掉
		-* ) return 1 ;;
		*[!A-Za-z0-9._:-]* ) return 1 ;;
	esac
	return 0
}

need_serial() {
	valid_serial "${1:-}" || die "序列号不合法: ${1:-<空>}"
}

# 型号名会进入 "serial<TAB>标签<TAB>状态" 这个协议，必须去掉制表符与换行，
# 否则调用方按 tab 切分会错位
sanitize_label() {
	tr -d '\t\r\n' | cut -c1-64
}

# ---------------------------------------------------------------- gnirehtet 定位

# 不假设 Homebrew 前缀。Homebrew 的 bin/gnirehtet 是一个先设 GNIREHTET_APK
# 再 exec 真实二进制的包装脚本，直接从里面读最可靠。
gnirehtet_apk() {
	local bin apk
	if [ -n "${GNIREHTET_APK:-}" ] && [ -f "${GNIREHTET_APK}" ]; then
		echo "$GNIREHTET_APK"; return 0
	fi
	bin="$(command -v gnirehtet 2>/dev/null)" || return 1
	if [ -f "$bin" ]; then
		apk="$(sed -n 's/.*GNIREHTET_APK="\([^"]*\)".*/\1/p' "$bin" 2>/dev/null | head -1)"
		if [ -n "$apk" ] && [ -f "$apk" ]; then echo "$apk"; return 0; fi
	fi
	for apk in "$(dirname "$bin")/../libexec/gnirehtet.apk" \
	           "$(dirname "$bin")/../share/gnirehtet/gnirehtet.apk"; do
		[ -f "$apk" ] && { echo "$apk"; return 0; }
	done
	return 1
}

# 版本串规整：只取开头的「数字和点」。
# Mac 侧的版本是从 Homebrew 的 Cellar 目录名推断的，修订号会写成 2.5.1_1；
# 手机侧取的是 APK 的 versionName（2.5.1）。直接字符串比较会永久判定「版本不一致」，
# 而重装并不能让两者相等——设备会永远卡在待启动，引导里重装 4 轮也修不好。
norm_version() {
	printf '%s' "${1:-}" | sed -n 's/^[^0-9]*\([0-9][0-9.]*\).*/\1/p'
}

# 从 APK 路径里的 Cellar 版本号推断 Mac 端版本；推断不出就返回空，
# 此时跳过版本一致性检查而不是误报
mac_apk_version() {
	local apk
	apk="$(gnirehtet_apk 2>/dev/null)" || return 0
	echo "$apk" | sed -n 's#.*/Cellar/gnirehtet/\([^/]*\)/.*#\1#p' | head -1
}

# ---------------------------------------------------------------- 设备查询

# adb devices -l 的一行形如：
#   1a2b3c4d  device  usb:1-1 product:example model:EXAMPLE_X1 device:example transport_id:6
# 只有 USB 连接的物理设备才带 usb: 字段。模拟器（emulator-5554）和无线调试
# 连上来的设备（192.168.x.x:5555）都没有这个字段——它们本身就有网络，
# 给它们反向共享既无意义也做不到，所以用这一个字段就能一次性排除两类。
# 一次调用里 usb_serials / ignored_devices / preflight 会各查一遍设备列表，
# 在进程内缓存一次。reconcile 只跑几百毫秒，期间设备状态变化会由下一个事件收敛。
_DEV_CACHED=0
_DEV_CACHE=""
devices_long() {
	if [ "$_DEV_CACHED" = "1" ]; then
		# 空缓存必须什么都不输出。printf 会补一个换行，
		# 那一行会被 awk 当成一条记录，统计出一台不存在的「被忽略设备」。
		[ -n "$_DEV_CACHE" ] && printf '%s\n' "$_DEV_CACHE"
		return 0
	fi
	if command -v adb >/dev/null 2>&1; then
		_DEV_CACHE="$(adb devices -l 2>/dev/null | tail -n +2 | grep -v '^[[:space:]]*$')"
	else
		_DEV_CACHE=""
	fi
	_DEV_CACHED=1
	[ -n "$_DEV_CACHE" ] && printf '%s\n' "$_DEV_CACHE"
	return 0
}

usb_serials() {
	devices_long | awk '$2=="device" && /(^| )usb:/ {print $1}' \
		| while IFS= read -r s; do valid_serial "$s" && echo "$s"; done
}

ignored_devices() {
	devices_long | awk '
		$2!="device" { print $1"\t"$2; next }
		/(^| )usb:/  { next }
		$1 ~ /^emulator-/ { print $1"\t模拟器"; next }
		$1 ~ /:/          { print $1"\t无线调试"; next }
		{ print $1"\t非 USB 连接" }
	'
}

# ioreg 里暴露了 ADB 接口的设备数。**只数对象头行**——
# 属性行里也含 "ADB Interface" 字样（`"USB Interface Name" = "ADB Interface"`），
# 一起数会正好翻倍，两台设备会被数成 4。
adb_iface_count() {
	ioreg -r -c IOUSBHostInterface -w0 2>/dev/null \
		| grep -cE '^ *\+-o ADB Interface' || true
}

# 插着但 adb 读不到的设备数。
#
# 这类设备在 adb 日志里是 "failed to get serial ... LIBUSB_ERROR_IO"：
# USB 枚举成功、ADB 接口也在，但读序列号的控制传输失败（USB 半死），
# 多见于睡眠唤醒之后或某个 USB 口接触不良。
#
# 早期版本要求 usb_serials **完全为空**才报告，于是「一台正常 + 一台卡住」的情况
# 什么都不说——用户只看到那台卡住的设备显示「离线」，完全想不到它其实插着，
# 更不会想到去换个 USB 口。改成按数量比对，差额就是卡住的台数。
# adb 能看见的实体 USB 设备条目数——**不管授权与否**。
#   - 带 usb: 字段的（正常授权的设备）
#   - 状态不是 device 的（unauthorized / offline）：这类行未必带 usb: 字段，
#     但只要不是模拟器、也不是 host:port 形式的无线设备，就是插着的实体设备
usb_visible_count() {
	devices_long | awk '
		/(^| )usb:/       { n++; next }
		$2=="device"      { next }
		$1 ~ /^emulator-/ { next }
		$1 ~ /:/          { next }
		                  { n++ }
		END { print n+0 }
	'
}

# 插着但 adb 完全读不到的台数。
#
# 早期版本拿 ifaces 减去 usb_serials（只含 state==device 的），于是**手机上没点
# 「允许 USB 调试」**的设备也被算成「USB 半死」，界面常驻提示「拔插它，或换一个 USB 口」——
# 把用户引到完全错误的方向，真正要做的是在手机屏幕上点允许。
# 现在减去的是「adb 能看见的所有实体设备」，未授权的那台会走 unauthorized= 那条提示。
usb_stuck_count() {
	local ifaces visible
	ifaces="$(adb_iface_count)"
	[ -n "$ifaces" ] || ifaces=0
	visible="$(usb_visible_count)"
	[ -n "$visible" ] || visible=0
	if [ "$ifaces" -gt "$visible" ]; then
		echo $((ifaces - visible))
	else
		echo 0
	fi
}

usb_stuck() { [ "$(usb_stuck_count)" -gt 0 ]; }

model_of() {
	local s="$1" m
	m="$(adb -s "$s" shell getprop ro.product.model 2>/dev/null | sanitize_label)"
	[ -n "$m" ] && echo "$m" || echo "$s"
}

# 手机上装没装客户端。整行比较而不是子串：`grep -q com.genymobile.gnirehtet`
# 也会被 com.genymobile.gnirehtet.foo 这类包名命中。
# adb shell 的输出带 \r，-x 之前必须先去掉。
client_installed() {
	adb -s "$1" shell pm list packages "$PKG" 2>/dev/null \
		| tr -d '\r' | grep -qxF -- "package:$PKG"
}

# 兜底判别：万一某种「USB 连上来的虚拟设备」骗过了 usb: 字段
is_emulator() {
	local s="$1" q hw
	q="$(adb -s "$s" shell getprop ro.kernel.qemu 2>/dev/null | tr -d '\r\n')"
	[ "$q" = "1" ] && return 0
	hw="$(adb -s "$s" shell getprop ro.hardware 2>/dev/null | tr -d '\r\n')"
	case "$hw" in
		goldfish | ranchu | vbox86 | vbox86p | cutf* ) return 0 ;;
	esac
	return 1
}

# 记住机型名，供设备离线时仍能显示可读名称。
#
# 不能「有内容就跳过」：离线预授权时 model_of 拿不到型号，写进去的是序列号本身，
# 之后设备真的插上来也不会再更新——列表里就永远显示一串序列号。
# 所以内容等于序列号时要再取一次（设备在线才取得到）。
remember_model() {
	local dir="$1" s="$2" cur
	cur="$(sanitize_label < "$dir/$s" 2>/dev/null || true)"
	[ -n "$cur" ] && [ "$cur" != "$s" ] && return 0
	model_of "$s" > "$dir/$s"
	return 0
}

is_allowed() { [ -f "$ALLOW_DIR/$1" ]; }
is_denied()  { [ -f "$DENY_DIR/$1" ]; }

label_of() {
	local s="$1"
	if [ -s "$ALLOW_DIR/$s" ]; then sanitize_label < "$ALLOW_DIR/$s"
	elif [ -s "$DENY_DIR/$s" ]; then sanitize_label < "$DENY_DIR/$s"
	else model_of "$s"; fi
}

# ---------------------------------------------------------------- relay

# 端口上监听的进程未必是我们的 relay——31416 不是注册端口，任何程序都可能用。
# 所以必须核对进程名，否则后面的 kill 会打到无关进程上。
# 除了进程名，还要核对所有者：同一台 Mac 上另一个用户也可能在跑 gnirehtet，
# 那个 relay 不是我们的，既不能用也杀不掉
relay_pid() {
	local p cmd owner me
	me="$(id -u)"

	# 快路径：用我们自己记下的 pid，避免每次都跑 lsof
	p="$(cat "$RELAY_PID_FILE" 2>/dev/null || true)"
	if [ -n "$p" ] && kill -0 "$p" 2>/dev/null; then
		cmd="$(ps -o comm= -p "$p" 2>/dev/null || true)"
		owner="$(ps -o uid= -p "$p" 2>/dev/null | tr -d ' ' || true)"
		case "$cmd" in
			*gnirehtet* ) [ "$owner" = "$me" ] && { echo "$p"; return 0; } ;;
		esac
	fi

	for p in $(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null); do
		cmd="$(ps -o comm= -p "$p" 2>/dev/null || true)"
		owner="$(ps -o uid= -p "$p" 2>/dev/null | tr -d ' ' || true)"
		case "$cmd" in
			*gnirehtet* )
				[ "$owner" = "$me" ] && { echo "$p"; return 0; }
				;;
		esac
	done
	return 1
}

relay_up() { relay_pid >/dev/null; }

# 指定端口上有没有非我们的监听者。默认查当前生效端口。
port_taken_by_other() {
	local port="${1:-$PORT}" p cmd owner me
	# 同一端口只能有一个监听者：若已确认是我们自己的 relay，就不可能被别人占，
	# 这样可以省掉 summary 里那次 lsof（最贵的单项）
	if [ "$port" = "$PORT" ]; then
		relay_pid >/dev/null && return 1
	fi
	me="$(id -u)"
	for p in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null); do
		cmd="$(ps -o comm= -p "$p" 2>/dev/null || true)"
		owner="$(ps -o uid= -p "$p" 2>/dev/null | tr -d ' ' || true)"
		case "$cmd" in
			*gnirehtet* )
				# 别的用户的 gnirehtet 同样算冲突
				[ "$owner" = "$me" ] || { echo "$p	${cmd:-未知进程}（属于 uid ${owner}）"; return 0; }
				;;
			* ) echo "$p	${cmd:-未知进程}"; return 0 ;;
		esac
	done
	return 1
}

# 当前端口被别的程序占了就换一个。返回 0 表示有可用端口（可能已切换）。
pick_port() {
	local other candidate i
	if ! other="$(port_taken_by_other "$PORT")"; then
		return 0                      # 当前端口可用
	fi
	log "端口 ${PORT} 被占用（${other}），尝试换一个"
	i=0
	while [ "$i" -lt "$PORT_TRIES" ]; do
		candidate=$((PORT_BASE + i))
		i=$((i + 1))
		[ "$candidate" = "$PORT" ] && continue
		if ! port_taken_by_other "$candidate" >/dev/null; then
			PORT="$candidate"
			echo "$PORT" > "$PORT_FILE"
			log "已切换到端口 $PORT"
			return 0
		fi
	done
	log "$PORT_BASE..$((PORT_BASE + PORT_TRIES - 1)) 全部被占用，无法启动"
	return 1
}

relay_start() {
	relay_up && return 0

	pick_port || return 1

	command -v gnirehtet >/dev/null 2>&1 || { log "gnirehtet 未安装"; return 1; }

	# launchd 会话的 maxfiles 软上限是 256（`launchctl limit maxfiles`），
	# 而 relay 每个连接占一个套接字。撑爆之后每个新包都被丢弃，日志里是
	#   ERROR Router: Cannot create route, dropping packet: Too many open files
	# 手机表现为「VPN 图标亮着但完全没网」，而且不会自行恢复——gnirehtet 的
	# UDP 连接要等超时才释放，同时应用的重试风暴会持续制造新连接。
	# 硬上限是 unlimited，所以抬高软上限不需要特权。exec 保证 $! 仍是 relay 的 pid。
	# 每次启动打一行分隔标记：fd_exhausted() 只看最后一次启动之后的内容，
	# 否则上一轮 relay 留在日志里的 ERROR 行会让心跳白重启一次 relay（打断所有共享）。
	printf '=== relay start %s ===\n' "$(date '+%F %T')" >> "$RELAY_LOG" 2>/dev/null || true
	( ulimit -n "$FD_LIMIT" 2>/dev/null || true
	  exec nohup gnirehtet relay -p "$PORT" >> "$RELAY_LOG" 2>&1 ) &
	echo $! > "$RELAY_PID_FILE"
	local i
	for i in $(seq 1 20); do
		sleep 0.25
		if relay_up; then
			# 记下这个 relay 是哪个版本的 gnirehtet 起的：brew upgrade 之后
			# 跑着的还是旧二进制，而手机端会被 try_fix_version 换成新版 APK，
			# 新手机端 ↔ 旧 relay 的症状就是最难查的那个「有 VPN 但没网」。
			mac_apk_version > "$STATE_DIR/relay.ver" 2>/dev/null || true
			log "relay 已启动 pid $(relay_pid)"; stamp; return 0
		fi
	done
	rm -f "$RELAY_PID_FILE"
	log "relay 启动失败: $(tail -2 "$RELAY_LOG" 2>/dev/null | tr '\n' ' ')"
	return 1
}

relay_stop() {
	local p
	p="$(relay_pid)" || return 0
	kill "$p" 2>/dev/null
	sleep 1
	# 只对确认是 gnirehtet 的进程升级到 KILL
	p="$(relay_pid)" && kill -9 "$p" 2>/dev/null
	rm -f "$RELAY_PID_FILE" "$STATE_DIR/relay.ver"
	stamp
	log "relay 已停止"
	return 0
}

# ---------------------------------------------------------------- DNS

# gnirehtet 没有「跟随宿主 DNS」的选项，不给 -d 就写死用 8.8.8.8，
# 境内会慢且拿不到就近 CDN 节点。所以每次下发前都现读一次本机 DNS，
# 并保留 8.8.8.8 作为兜底（本机 DNS 若是链路本地地址，手机侧走 relay 仍可达）。
is_ipv4() {
	local a="$1" part cnt keep oldIFS
	case "$a" in
		"" | *[!0-9.]* ) return 1 ;;
	esac
	oldIFS="$IFS"; IFS='.'; cnt=0; keep=1
	for part in $a; do
		cnt=$((cnt + 1))
		case "$part" in
			"" | *[!0-9]* ) keep=0 ;;
			* ) [ "$part" -le 255 ] || keep=0 ;;
		esac
	done
	IFS="$oldIFS"
	[ "$cnt" -eq 4 ] && [ "$keep" -eq 1 ]
}

dns_list() {
	local d
	# 必须遍历所有 nameserver 条目，不能只看 nameserver[0]：
	# 路由器广告 IPv6 DNS 时它会占据 [0]（例如 fe80::1%en0），而 gnirehtet 的 -d
	# 只支持 IPv4，只读 [0] 就会判定为「没有可用 DNS」而回落到写死的 8.8.8.8——
	# 恰好绕开了这个功能本身要解决的问题。
	for d in $(scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}'); do
		is_ipv4 "$d" || continue
		# 手机侧拿到的 DNS 是**它自己**要去连的地址（包经隧道从 Mac 发出去）。
		# 回环地址上的解析器（AdGuard / dnscrypt / Pi-hole 常绑 127.x）手机根本到不了，
		# 下发过去只会让解析全部超时后才降级到 8.8.8.8。链路本地和组播同理
		# （mDNS 的 224.0.0.251 会混在 scutil --dns 的输出里）。
		case "$d" in
			0.0.0.0 | 255.255.255.255 ) continue ;;
			127.* ) continue ;;
			169.254.* ) continue ;;
			22[4-9].* | 23[0-9].* ) continue ;;
		esac
		echo "$d,8.8.8.8"
		return 0
	done
	echo ""
	return 0
}

# relay 活着不代表通道活着：USB 重新枚举会摧毁 adb reverse 隧道，
# 而手机端的 VpnService 不会跟着退出。此时 gnirehtet start 判定「客户端已在运行」
# 什么都不做，状态显示 shared 但流量进了 tun0 就死掉——现象就是「有 VPN 但没网」。
#
# gnirehtet 有专门的 tunnel 子命令重建 adb reverse，代价远小于整个重启，
# 而且不会打断手机端的 VPN。
# FD 耗尽是完全静默的故障：界面绿灯、隧道正常、手机 VPN 亮着，就是一个包都过不去。
# relay 日志里只有一行 ERROR 埋在几千条流量记录里。只看日志尾部，成本可忽略。
fd_exhausted() {
	# awk 在每个 "=== relay start" 标记处清空缓冲：只留最后一次启动之后的行
	tail -200 "$RELAY_LOG" 2>/dev/null \
		| awk '/^=== relay start /{buf=""; next} {buf = buf $0 "\n"} END{printf "%s", buf}' \
		| grep -q 'Too many open files'
}

tunnel_ok() {
	adb -s "$1" reverse --list 2>/dev/null | grep -q "tcp:$PORT"
}

repair_tunnel() {
	local s="$1"
	tunnel_ok "$s" && return 0
	log "$s 的 adb reverse 隧道已丢失，重建"
	gnirehtet tunnel "$s" -p "$PORT" >/dev/null 2>&1
}

# relay 与 client 必须用同一个端口，否则 client 连不上。
#
# 回显不能丢。`gnirehtet start` 内部跑的是 `adb shell am start`，小米
# 「USB 调试（安全设置）」没开时报的 WRITE_SECURE_SETTINGS **只出现在这里**。
# 早期版本把它直接丢进 /dev/null，而引导层却去 relay.log 里 grep 这个串——
# relay.log 只由 relay 进程写，那个分支永远不可能命中，用户拿到的永远是
# 泛化的「已允许，但没有连上」。所以把最后一次启动的回显存下来（last-start 可读）。
gnirehtet_start_one() {
	local s="$1" d="$2" out rc
	if [ -n "$d" ]; then
		out="$(gnirehtet start "$s" -d "$d" -p "$PORT" 2>&1)"; rc=$?
	else
		out="$(gnirehtet start "$s" -p "$PORT" 2>&1)"; rc=$?
	fi
	printf '%s' "$out" | tail -c 2000 > "$STATE_DIR/laststart.$s" 2>/dev/null || true
	return "$rc"
}

# 切换 Wi-Fi / 接入 VPN 后本机 DNS 会变，手机侧却还用着旧的。
# 但网络切换过程中 DNS 会短暂抖动，立刻重启会让隧道反复断开，
# 所以要求同一个新值连续两次心跳都出现才下发。
sync_dns() {
	[ -f "$FLAG" ] || return 0
	[ "$(active_list | wc -l | tr -d ' ')" -eq 0 ] && return 0

	local now applied cand s
	now="$(dns_list)"
	applied="$(cat "$DNS_APPLIED" 2>/dev/null || true)"
	[ "$now" = "$applied" ] && { rm -f "$DNS_CANDIDATE"; return 0; }

	cand="$(cat "$DNS_CANDIDATE" 2>/dev/null || true)"
	if [ "$now" != "$cand" ]; then
		echo "$now" > "$DNS_CANDIDATE"
		log "观察到 DNS 变化候选: ${now:-gnirehtet 默认}，下次心跳确认后下发"
		return 0
	fi

	log "本机 DNS 变化: ${applied:-未记录} -> ${now:-gnirehtet 默认}，重新下发"
	for s in $(active_list); do
		if [ -n "$now" ]; then
			gnirehtet restart "$s" -d "$now" -p "$PORT" >/dev/null 2>&1
		else
			gnirehtet restart "$s" -p "$PORT" >/dev/null 2>&1
		fi
	done
	echo "$now" > "$DNS_APPLIED"
	rm -f "$DNS_CANDIDATE"
	stamp
	return 0
}

# ---------------------------------------------------------------- 单设备条件

# dumpsys package 要 ~90ms。手机端版本只在重装时会变，而重装必然经过
# try_fix_version（那里会清缓存），所以按 "Mac版本:手机版本" 缓存是安全的。
phone_apk_version() {
	local s="$1" cache mv line
	cache="$STATE_DIR/ver.$s"
	mv="$(mac_apk_version)"
	if [ -r "$cache" ]; then
		line="$(cat "$cache" 2>/dev/null || true)"
		case "$line" in
			"$mv:"* ) echo "${line#*:}"; return 0 ;;
		esac
	fi
	local pv
	pv="$(adb -s "$s" shell dumpsys package "$PKG" 2>/dev/null \
		| sed -n 's/.*versionName=\([^ ]*\).*/\1/p' | head -1 | tr -d '\r\n')"
	[ -n "$pv" ] && printf '%s:%s\n' "$mv" "$pv" > "$cache" 2>/dev/null
	echo "$pv"
}

# 手机端客户端是否真的在运行。
#
# 为什么必须单独查：`gnirehtet start` 的退出码 0 只代表 intent 已发出，
# 不代表客户端起来了、更不代表连上了 relay。而 client_start 原来紧接着就
# mark_active，于是状态立刻变成「共享中」——实测过一台设备显示 shared、
# tunnel=ok，但手机上 curl 失败、relay 零新增连接，全是假的。
#
# 最常见的真实原因是新设备第一次运行时 Android 弹出的 VPN「连接请求」授权框
# 没人点。没有这个检查，用户只会看到「共享中」然后纳闷为什么没网。
client_running() {
	adb -s "$1" shell dumpsys activity services "$PKG" 2>/dev/null | grep -q 'ServiceRecord'
}

# 「确定没在运行」——比 client_running 更保守的版本，用于 heal 这种会主动停共享的地方。
# dumpsys 即使一个服务都没有也会打表头（"ACTIVITY MANAGER SERVICES ... (nothing)"），
# 所以回显为空只可能是 adb 抽风：那种情况按「还在跑」处理，宁可少动一次，
# 也不要把一个好好的共享掐掉。
client_definitely_dead() {
	local out
	out="$(adb -s "$1" shell dumpsys activity services "$PKG" 2>/dev/null)"
	[ -n "$out" ] || return 1
	printf '%s' "$out" | grep -q 'ServiceRecord' && return 1
	return 0
}


# 手机是否已有自己的网络（排除我们建的 VPN）。
# dumpsys 的格式跨 Android 版本会变，匹配不到时按「没有自己的网络」处理——
# 宁可多接管一次，也不要因为解析失败而静默不工作。
has_own_network() {
	adb -s "$1" shell dumpsys connectivity 2>/dev/null \
		| grep -qE 'ni\{(WIFI|MOBILE|ETHERNET)[^ ]* CONNECTED'
}

# 回显失败原因；返回 0 表示这台设备可以开始共享
preflight() {
	local s="${1:-}"
	valid_serial "$s" || { echo "序列号不合法"; return 1; }
	command -v gnirehtet >/dev/null 2>&1 || { echo "gnirehtet 未安装"; return 1; }
	command -v adb >/dev/null 2>&1 || { echo "adb 未安装"; return 1; }
	# 自动模式是总开关：关着时 reconcile 第一件事就是 stop_all 然后返回，
	# 所以任何设备都不可能开始共享。不在这里报出来的话，`allow` 会照样写进允许列表、
	# 界面把它显示成「已允许·待启动」、按钮翻成「停止共享」，而手机上什么都没发生——
	# 引导层还会把原因误判成「请在手机上允许 VPN 连接」。
	[ -f "$FLAG" ] || { echo "自动模式已关闭"; return 1; }
	usb_serials | grep -qxF -- "$s" || { echo "设备不在线，或不是 USB 连接的真机"; return 1; }
	is_emulator "$s" && { echo "模拟器设备，自身已有网络，无需共享"; return 1; }
	client_installed "$s" || { echo "手机端未安装客户端"; return 1; }

	local mv pv mvn pvn
	mv="$(mac_apk_version)"; pv="$(phone_apk_version "$s")"
	mvn="$(norm_version "$mv")"; pvn="$(norm_version "$pv")"
	if [ -n "$mvn" ] && [ -n "$pvn" ] && [ "$mvn" != "$pvn" ]; then
		echo "版本不一致 Mac=$mv 手机=$pv"; return 1
	fi

	if [ -f "$OFFLINE_ONLY" ] && has_own_network "$s"; then
		echo "手机已有自己的网络（仅无网时接管已启用）"; return 1
	fi
	return 0
}

try_fix_version() {
	local s="$1" apk
	apk="$(gnirehtet_apk 2>/dev/null)" || return 1
	rm -f "$STATE_DIR/ver.$s"           # 装完版本会变，缓存必须失效
	# -d 允许降级：手机上的版本比 Mac 侧新时（用户从别处装过），
	# 不带 -d 会 INSTALL_FAILED_VERSION_DOWNGRADE，然后就永远卡在「版本不一致」
	adb -s "$s" install -r -d "$apk" >/dev/null 2>&1 || return 1
	rm -f "$STATE_DIR/ver.$s"
	[ "$(mac_apk_version)" = "$(phone_apk_version "$s")" ]
}

# 手机端客户端的安装与推送。UI 与命令行共用同一份实现，
# 避免引导逻辑在两处漂移（Swift 前端曾因为没有这层而完全丢掉了引导）。
install_client() {
	local s="$1" apk out
	apk="$(gnirehtet_apk 2>/dev/null)" || { echo "找不到 gnirehtet.apk"; return 1; }
	rm -f "$STATE_DIR/ver.$s"
	out="$(adb -s "$s" install -r -d "$apk" 2>&1)"
	rm -f "$STATE_DIR/ver.$s"

	# 签名冲突必须**优先**判：这种情况手机上装着一个同包名的旧版，
	# 只看「包在不在」会把它误判成安装成功，然后一路卡在「版本不一致」上——
	# 而重装同样会失败，用户永远出不来。
	case "$out" in
		*INSTALL_FAILED_UPDATE_INCOMPATIBLE* | *"signatures do not match"* | *INSTALL_FAILED_DUPLICATE_PERMISSION*)
			echo "incompatible"
			log "$s 安装失败：手机上已有签名不同的同包名应用，需先卸载"
			return 1 ;;
	esac

	# 其余情况以实际包状态为准，不依赖 adb 的输出文案
	if client_installed "$s"; then
		echo "ok"
		log "$s 已安装手机端客户端"
		return 0
	fi

	case "$out" in
		*INSTALL_FAILED_USER_RESTRICTED*)
			# 小米 / HyperOS 默认禁止通过 adb 安装，需在开发者选项里打开「USB 安装」
			echo "restricted"
			log "$s 安装被拦截（USB 安装未开启）"
			return 1 ;;
	esac

	printf '%s\n' "$out" | tr '\n' ' '
	echo
	log "$s 安装失败: $(printf '%s' "$out" | tr '\n' ' ')"
	return 1
}

# 卸载手机端客户端。用在「签名不一致」这条失败路径上——那种情况下不先卸掉旧的，
# 无论 adb 装还是手机上手动点都会失败。
uninstall_client() {
	local s="$1"
	# 设备不在线时 adb uninstall 会失败、client_installed 也查不到，
	# 于是「查不到」被当成「已卸掉」——和 heal 踩过的是同一类坑。必须先要求在线。
	usb_serials | grep -qxF -- "$s" || { echo "设备不在线"; return 1; }
	rm -f "$STATE_DIR/ver.$s"
	adb -s "$s" uninstall "$PKG" >/dev/null 2>&1 || true
	rm -f "$STATE_DIR/ver.$s"
	if client_installed "$s"; then
		echo "卸载失败，手机上仍装着 $PKG"
		return 1
	fi
	echo "ok"
	log "$s 已卸载手机端客户端"
	return 0
}

# 绕开小米「USB 安装」限制的退路：推到下载目录让用户在手机上手动点安装
push_client() {
	local s="$1" apk
	apk="$(gnirehtet_apk 2>/dev/null)" || { echo "找不到 gnirehtet.apk"; return 1; }
	adb -s "$s" push "$apk" /sdcard/Download/ >/dev/null 2>&1 \
		|| { echo "推送失败"; return 1; }
	echo "ok"
	log "$s 已把 APK 推送到 /sdcard/Download/"
	return 0
}

open_dev_options() {
	adb -s "$1" shell am start -a com.android.settings.APPLICATION_DEVELOPMENT_SETTINGS \
		>/dev/null 2>&1
}

# 把用户直接送到 APK 所在的位置。
#
# 小米在「USB 安装」关闭时会拦掉一切 adb 安装路径——实测 `adb install`、
# `pm install`（含 /data/local/tmp）、会话式 install-create/write/commit 全部返回
# INSTALL_FAILED_USER_RESTRICTED，没有绕法。所以只能推送 APK 让用户在手机上点，
# 而「让用户自己去找文件」是很糟的体验，这里用 VIEW_DOWNLOADS 把「下载」界面直接打开。
# 实测前台会变成 com.google.android.documentsui/ViewDownloadsActivity。
open_downloads() {
	adb -s "$1" shell am start -a android.intent.action.VIEW_DOWNLOADS >/dev/null 2>&1
}

# 一台设备当前为什么没在共享。已在共享、或条件都满足（只是还没启动）则输出空。
#
# 存在的意义：reconcile 会故意吞掉 client_start 的失败（自动路径必须静默，
# 插线充电不该被弹窗打扰），于是 allow 也返回 0，调用方无从得知失败。
# 界面只能显示「已允许·待启动」，用户完全不知道卡在哪。
why_blocked() {
	local s="$1" reason
	active_list | grep -qxF -- "$s" && return 0
	if ! reason="$(preflight "$s")"; then
		printf '%s\n' "$reason"
		return 0
	fi
	# preflight 全过却仍然没起来：多半是手机上的 VPN「连接请求」授权框没人点，
	# 也可能是「USB 调试（安全设置）」没开导致 am start 被拒。
	# 这两种情况在 Mac 侧再点几次都没用，必须让用户知道要去手机上做什么。
	if [ -s "$STATE_DIR/startfail.$s" ]; then
		head -1 "$STATE_DIR/startfail.$s"
		return 0
	fi
	return 0
}

# 同一个跳过原因只记一次。一台永久卡住的设备（客户端没装、手机自己有网……）
# 会让心跳每 20 秒写一行「跳过: …」，一天上万行，把真正的事件冲掉。原因变了才记。
log_skip() {
	local s="$1" reason="$2" f="$STATE_DIR/skip.$s"
	[ "$(cat "$f" 2>/dev/null || true)" = "$reason" ] && return 0
	printf '%s\n' "$reason" > "$f" 2>/dev/null || true
	log "$s 跳过: $reason"
	return 0
}

# ---------------------------------------------------------------- client

active_list() { sort -u "$ACTIVE" 2>/dev/null | grep -v '^$' || true; }

mark_active() { active_list | grep -qxF -- "$1" || echo "$1" >> "$ACTIVE"; }

unmark_active() {
	grep -vxF -- "$1" "$ACTIVE" 2>/dev/null > "$ACTIVE.tmp" || true
	mv "$ACTIVE.tmp" "$ACTIVE" 2>/dev/null || true
}

client_start() {
	local s="$1" d reason

	# 已经在共享的设备走快路径：只补一次幂等的 start 当作自愈。
	#
	# 关键是**不能**先 stop。下面那句 `gnirehtet stop` 是为了清理拔插后残留在
	# 手机上的僵尸 VPN，只在首次启动时才需要；对已在共享的设备执行，等于每个
	# 设备事件都把隧道拆掉重建一次（relay 日志里成对的 disconnect+connect）。
	# USB 接触不良时事件每分钟好几次，手机就会不停瞬断——表现就是「莫名自动断线」。
	# 同时跳过 preflight（约 150ms 的 adb 往返），它在首次启动时已经查过了。
	if active_list | grep -qxF -- "$s"; then
		relay_start || return 1
		# 去掉无条件 stop 之后，隧道的重建必须显式做——
		# 原先是靠 stop+start 顺带重建的，那也是隧道反复抖动的根源
		repair_tunnel "$s"
		gnirehtet_start_one "$s" "$(dns_list)"
		return 0
	fi

	if ! reason="$(preflight "$s")"; then
		case "$reason" in
			版本不一致*)
				try_fix_version "$s" || { log_skip "$s" "$reason"; return 1; }
				# 版本是在其余条件之前判的，修好后必须重跑一遍，
				# 否则「仅无网时接管」这类后续条件会被跳过
				if ! reason="$(preflight "$s")"; then
					log_skip "$s" "（重装后）$reason"; return 1
				fi
				;;
			*) log_skip "$s" "$reason"; return 1 ;;
		esac
	fi
	relay_start || return 1
	d="$(dns_list)"
	# 插回线后手机上可能残留上次的僵尸 VPN，先掐掉再启动
	gnirehtet stop "$s" >/dev/null 2>&1
	gnirehtet_start_one "$s" "$d" || { log "$s 启动失败"; return 1; }

	# 等客户端真的跑起来再标记为共享中。intent 发出 ≠ 客户端启动，
	# 尤其是新设备要先在手机上点掉 VPN「连接请求」授权框。
	local i
	for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
		client_running "$s" && break
		sleep 0.5
	done
	if ! client_running "$s"; then
		# 留一个标记给 why_blocked，内容就是给用户看的那句话。
		# preflight 查不出这一类失败——它只看 Mac 侧和包状态，而「允许 VPN 连接」
		# 这一步发生在手机屏幕上。用户在手机上删掉/撤销了保存的 VPN 配置之后必然会
		# 再弹一次授权框，没有这个标记的话界面只会显示光秃秃的「已允许·待启动」，
		# 而它暗示的是「马上就会启动」。
		local fail_txt="手机上的 VPN 连接请求未确认"
		case "$(cat "$STATE_DIR/laststart.$s" 2>/dev/null)" in
			*WRITE_SECURE_SETTINGS* | *"Permission Denial"* | *SecurityException* )
				fail_txt="无法拉起手机端客户端（需要开启「USB 调试（安全设置）」）" ;;
		esac
		printf '%s\n' "$fail_txt" > "$STATE_DIR/startfail.$s" 2>/dev/null || true
		log "$s 客户端未启动：$fail_txt"
		return 1
	fi

	# 启动完必须验证隧道真的建起来了。拔插之后走的就是这条完整路径，
	# 而 gnirehtet start 在手机端客户端「看起来还在运行」时会跳过 tunnel 建立，
	# 结果是状态写成 shared 但一个包都过不去。
	repair_tunnel "$s"
	rm -f "$STATE_DIR/startfail.$s" "$STATE_DIR/skip.$s" 2>/dev/null || true
	# 设备此刻确定在线：如果 allow 里记的还是序列号（离线预授权留下的），升级成机型名
	is_allowed "$s" && remember_model "$ALLOW_DIR" "$s"
	mark_active "$s"
	stamp
	echo "$d" > "$DNS_APPLIED"
	rm -f "$DNS_CANDIDATE"
	log "$s 已开始共享 (DNS=${d:-8.8.8.8})"
	return 0
}

client_stop() {
	local s="$1"
	valid_serial "$s" || return 1
	gnirehtet stop "$s" >/dev/null 2>&1
	rm -f "$STATE_DIR/startfail.$s" "$STATE_DIR/skip.$s" 2>/dev/null || true
	unmark_active "$s"
	stamp
	log "$s 已停止共享"
	return 0
}

# ---------------------------------------------------------------- 对账

reconcile() {
	local online desired s ign sig

	if [ ! -f "$FLAG" ]; then
		stop_all
		return 0
	fi

	# 被忽略的设备只在清单变化时记一次日志，避免每个事件都刷屏
	ign="$(ignored_devices)"
	if [ -n "$ign" ]; then
		sig="$(echo "$ign" | shasum | cut -c1-16)"
		if [ "$sig" != "$(cat "$IGN_SIG" 2>/dev/null || true)" ]; then
			log "已忽略: $(echo "$ign" | tr '\t' '=' | tr '\n' ' ')"
			echo "$sig" > "$IGN_SIG"
		fi
	else
		rm -f "$IGN_SIG"
	fi

	prune_asked
	prune_pending

	online="$(usb_serials)"
	desired=""
	for s in $online; do
		if is_allowed "$s"; then
			desired="$desired $s"
		elif is_denied "$s"; then
			:
		else
			queue_ask "$s"
		fi
	done

	# 该停的先停。但「设备暂时消失」和「用户主动取消共享」要区别对待：
	# 前者可能只是 USB 抖动，拆了马上又要重建；后者必须立即生效。
	local now first
	now="$(date +%s)"
	for s in $(active_list); do
		case " $desired " in
			*" $s "*)
				rm -f "$STATE_DIR/missing.$s"
				continue ;;
		esac

		if is_allowed "$s"; then
			# 仍在允许列表里却不在线 —— 可能是闪断，给宽限期
			first="$(cat "$STATE_DIR/missing.$s" 2>/dev/null || true)"
			case "$first" in
				"" | *[!0-9]* )
					echo "$now" > "$STATE_DIR/missing.$s"
					log "$s 暂时消失，宽限 ${MISSING_GRACE}s 后再判定"
					continue ;;
			esac
			if [ $((now - first)) -lt "$MISSING_GRACE" ]; then
				continue
			fi
			log "$s 消失超过 ${MISSING_GRACE}s，停止共享"
		fi
		rm -f "$STATE_DIR/missing.$s"
		client_stop "$s"
	done

	# 该开的再开。gnirehtet start 本身幂等，重复调用无害，正好用来自愈
	for s in $desired; do
		client_start "$s" >/dev/null || true
	done

	# 宽限期内 desired 为空但 active 非空：此时停 relay 等于白等宽限期
	if [ -z "${desired// /}" ] && [ "$(active_list | wc -l | tr -d ' ')" -eq 0 ]; then
		relay_stop
	fi
	return 0
}

stop_all() {
	local s
	for s in $(active_list); do client_stop "$s"; done
	: > "$ACTIVE"
	rm -f "$DNS_APPLIED" "$DNS_CANDIDATE" "$STATE_DIR"/missing.* "$STATE_DIR"/gone.* \
		"$STATE_DIR"/startfail.* "$STATE_DIR"/laststart.* "$STATE_DIR"/skip.* \
		"$STATE_DIR"/retry.at 2>/dev/null
	relay_stop
}

# 心跳用的轻量检查：一次 lsof 看 relay 是否还活着，外加一次 scutil 比对 DNS
health() {
	[ -f "$FLAG" ] || return 0
	trim_log

	# 客户端被系统清理时 active 会一直谎报「共享中」——快路径为了省时间跳过了
	# preflight，所以永远发现不了。这一项原来只在 heal（300 秒）里查，实测一次
	# HyperOS「锁屏后清理内存」造成的掉线要 332 秒才恢复：10:38:10 进程被杀
	# （relay 0.6 秒后记下 Client #0 disconnected）→ 10:43:12 heal 才发现并移出
	# 共享列表 → 10:43:42 才重新起来。而那个清理每次锁屏都会跑，是常规事件不是异常。
	#
	# 移到心跳里之后上限压到一个心跳（20 秒），发现和重新拉起在同一轮完成。
	# 必须放在函数最前面：下面那些分支都会 return，排在它们后面就会被跳过。
	#
	# 成本实测（同一台设备，交错各 8 次取中位）：
	#   dumpsys activity services  74ms   ← 这里用的
	#   pidof                      87ms
	#   pm list packages           90ms
	# 三者同一个量级，所以没必要为「便宜」另写一个 pidof 判据——那样还更贵，
	# 而且只能发现「进程被杀」，发现不了「进程活着但服务没在跑」（手机上撤销了
	# 保存的 VPN 配置）。直接复用 client_definitely_dead，两类一起覆盖。
	local cs
	for cs in $(active_list); do
		# 不在线的设备交给 reconcile 的宽限期逻辑，这里不越权（和 heal 同一个约定）
		usb_serials | grep -qxF -- "$cs" || continue
		if client_definitely_dead "$cs"; then
			log "$cs 手机端客户端没在运行（被系统清理或 VPN 已撤销），移出共享列表"
			client_stop "$cs"
		fi
	done

	# 有「已允许、在线、但不在共享」的设备就再对一次账。开机时手机可能还没授权完
	# 导致首次对账失败，不在这里重试就只能等用户拔插。
	#
	# 这段原来被包在「active 为空」的分支里，多设备时是坏的：两台在共享、其中一台的
	# 客户端被系统杀掉之后，heal 只把它移出 active、自己不重新拉起，下一轮 heal 又
	# 只遍历 active_list（它已经不在里面了），而这里被「active 不为空」挡在门外
	# ——没有设备事件的话它永远不会恢复。单设备之所以一直没暴露，纯粹是因为移出后
	# active 恰好变空、正好命中了那条分支。
	if [ -n "$(pending_starts)" ]; then
		# 设备永久卡住时（客户端没装、手机自己有网……）这里会每 20 秒对一次账。
		# 对账本身幂等、无害，但会持续写日志，所以限速到 60 秒一次。
		local rlast rnow
		rlast="$(cat "$STATE_DIR/retry.at" 2>/dev/null || echo 0)"
		case "$rlast" in "" | *[!0-9]* ) rlast=0 ;; esac
		rnow="$(date +%s)"
		if [ $((rnow - rlast)) -ge 60 ]; then
			echo "$rnow" > "$STATE_DIR/retry.at" 2>/dev/null || true
			log "有已允许但未共享的设备，触发对账"
			reconcile
			return 0        # 对账已经把该起的都起了，这一轮不必再查下去
		fi
		# 被限速挡住时必须继续往下走，不能 return：永久卡住的设备会让 pending_starts
		# 一直非空，在这里返回等于把 relay / fd / 版本 / 隧道那些检查永久饿死。
	fi

	if [ "$(active_list | wc -l | tr -d ' ')" -eq 0 ]; then
		return 0        # 下面的检查都以「有设备在共享」为前提
	fi

	if ! relay_up; then
		log "relay 已不在，触发对账"
		reconcile
		return 0
	fi

	# FD 耗尽的 relay 不会自愈（gnirehtet 的 UDP 连接要等超时才释放，
	# 而应用的重试风暴会持续制造新连接），只能重启
	if fd_exhausted; then
		log "relay 文件描述符耗尽，重启 relay"
		relay_stop
		: > "$RELAY_LOG"
		reconcile
		return 0
	fi

	# brew upgrade gnirehtet 之后，跑着的 relay 还是旧二进制（inode 还在、路径已经没了），
	# 而手机端会被 try_fix_version 换成新版 APK —— 新手机端 ↔ 旧 relay，
	# 症状就是那个最难查的「手机 VPN 亮着但一个包都过不去」。比一次版本，不一致就重启。
	# mac_apk_version 只读一个包装脚本，不碰 adb，成本可忽略。
	local rver cver
	rver="$(cat "$STATE_DIR/relay.ver" 2>/dev/null || true)"
	cver="$(mac_apk_version)"
	if [ -n "$rver" ] && [ -n "$cver" ] && [ "$rver" != "$cver" ]; then
		log "relay 由旧版本 gnirehtet 启动（${rver}，当前 ${cver}），重启 relay"
		relay_stop
		reconcile
		return 0
	fi

	# 有设备在宽限期里等待判定：必须再跑一次对账才能真正收敛。
	# 拔线通常只产生一个事件，那次对账只打了标记就返回；如果这里不管，
	# 之后没有任何东西会重新评估它——设备会一直显示「共享中」。
	if ls "$STATE_DIR"/missing.* >/dev/null 2>&1; then
		reconcile
		return 0
	fi

	# 上面那段依赖「有设备事件打过宽限标记」，但**拔掉最后一台**时根本不会有事件：
	# adb track-devices 在设备列表为空时只发 4 字节的 "0000"（没有换行），
	# 守护进程凑不出一整行，读不到事件 → 没人打标记 → 没人重新评估。
	# 表现是拔了线界面还显示「共享中」、relay 一直挂着。所以这里必须自己查一遍。
	local gs gone=0
	for gs in $(active_list); do
		usb_serials | grep -qxF -- "$gs" || gone=1
	done
	if [ "$gone" -eq 1 ]; then
		log "共享列表里有设备已不在线，触发对账"
		reconcile
		return 0
	fi

	# 没有设备事件但隧道断了的情况：单纯等事件永远等不到
	local s
	for s in $(active_list); do
		usb_serials | grep -qxF -- "$s" || continue
		repair_tunnel "$s"
	done

	sync_dns
	return 0
}

# 已允许、在线、但当前没在共享的设备
pending_starts() {
	local s
	for s in $(usb_serials); do
		is_allowed "$s" || continue
		active_list | grep -qxF -- "$s" && continue
		echo "$s"
	done
}

# 定期自愈：gnirehtet start 是幂等的（已启动则什么都不做），
# 所以直接重复调用即可把被系统清理掉的 client 拉回来，不需要先检测它死了没
heal() {
	[ -f "$FLAG" ] || return 0
	if [ "$(active_list | wc -l | tr -d ' ')" -eq 0 ]; then
		[ -n "$(pending_starts)" ] && reconcile
		return 0
	fi
	relay_start || return 1
	local s d
	d="$(dns_list)"
	for s in $(active_list); do
		if ! usb_serials | grep -qxF -- "$s"; then
			# 是否真的该移除由 reconcile 的宽限期逻辑决定，这里不越权
			continue
		fi
		# 客户端被卸载或被系统清理时，active 会一直谎报「共享中」，
		# 而快路径为了省时间跳过了 preflight，所以永远发现不了。
		# heal 每 5 分钟才跑一次，这里多一次 pm list（约 90ms）可以忽略。
		if ! client_installed "$s"; then
			log "$s 手机端客户端已不在，移出共享列表"
			client_stop "$s"
			continue
		fi
		# 「客户端装着、服务却没在跑」（被系统清理，或用户在手机上撤销 / 删除了保存的
		# VPN 配置）的检查已经移到 health 里，20 秒一轮而不是 300 秒——放在这里的话
		# 恢复要等最长 332 秒（实测）。这里不再重复查：heal 的每一次调用都发生在
		# 一次心跳里，health 必然已经先跑过同一项，留在这里就是一段永远不会命中的
		# 死代码，而没人跑的分支一定会腐烂。
		# 「仅无网时接管」的语义应该是持续成立的：手机中途连上自己的 Wi-Fi 之后，
		# 流量仍然全走 VPN——也就是仍然在用 Mac 的网，正是这个开关想避免的事。
		# 所以发现它有自己的网络就释放。不需要防抖：释放之后 preflight 会拦住重新接管，
		# 等它真的又没网了才接回来，而 5 分钟的采样间隔本身就是防抖。
		if [ -f "$OFFLINE_ONLY" ] && has_own_network "$s"; then
			log "$s 已连上自己的网络，按「仅无网时接管」释放"
			client_stop "$s"
			continue
		fi
		gnirehtet_start_one "$s" "$d"
	done
	return 0
}

# 设备真正断开后清掉它的询问记录，于是重新插上会再问一次——
# 「每次连接询问一次」比「每次开机询问一次」更符合直觉：重新插上正是用户
# 表达「我想重新决定」的动作。8 秒宽限避免 USB 抖动导致反复弹窗。
prune_asked() {
	local list s first now
	# 先取快照：unmark_asked 会重写 ASKED，边读边改会丢数据
	list="$(grep -v '^$' "$ASKED" 2>/dev/null || true)"
	[ -n "$list" ] || return 0
	now="$(date +%s)"
	for s in $list; do
		if usb_serials | grep -qxF -- "$s"; then
			rm -f "$STATE_DIR/gone.$s"
			continue
		fi
		first="$(cat "$STATE_DIR/gone.$s" 2>/dev/null || true)"
		case "$first" in
			"" | *[!0-9]* )
				echo "$now" > "$STATE_DIR/gone.$s"
				continue ;;
		esac
		[ $((now - first)) -lt "$MISSING_GRACE" ] && continue
		rm -f "$STATE_DIR/gone.$s"
		unmark_asked "$s"
	done
}

# 待询问队列的清理。
#
# PENDING 在 ~/.config 下是**持久**的，而「本次连接已问过」的记录在 $TMPDIR 里开机即失效。
# App 当时没在运行（用户退出过、open 失败、或者干脆没装）时排进去的条目会一直留着，
# 下次启动 App 就会弹窗询问一台早就拔掉的设备——点「共享」还会把它写进允许列表。
# 设备不在线、或者已经有结论（在允许/拒绝列表里）的，直接清掉。
prune_pending() {
	local list s keep
	list="$(grep -v '^$' "$PENDING" 2>/dev/null || true)"
	[ -n "$list" ] || return 0
	keep=""
	for s in $list; do
		valid_serial "$s" || continue
		usb_serials | grep -qxF -- "$s" || continue
		is_allowed "$s" && continue
		is_denied "$s" && continue
		keep="$keep$s"$'\n'
	done
	[ "$keep" = "$list"$'\n' ] && return 0
	printf '%s' "$keep" > "$PENDING.tmp" 2>/dev/null || return 0
	mv "$PENDING.tmp" "$PENDING" 2>/dev/null || true
	return 0
}

# 陌生设备：记入待询问队列并唤起 App。同一次连接内只问一次。
queue_ask() {
	local s="$1"
	grep -qxF -- "$s" "$ASKED" 2>/dev/null && return 0
	echo "$s" >> "$ASKED"
	grep -qxF -- "$s" "$PENDING" 2>/dev/null || echo "$s" >> "$PENDING"
	stamp
	log "$s 是陌生设备，唤起 App 询问"
	open_app
}

# 用构建时记录的绝对路径，而不是 open -a 按名字找——
# 按名字可能命中同名的其他应用
open_app() {
	local p
	p="$(cat "$SELF_DIR/app-path" 2>/dev/null || true)"
	if [ -n "$p" ] && [ -d "$p" ]; then
		open "$p" 2>/dev/null && return 0
	fi
	open -a MacToAndroid 2>/dev/null && return 0
	log "无法唤起 App，请手动点击"
	return 1
}

# ---------------------------------------------------------------- 状态输出

# 每行: serial<TAB>标签<TAB>状态
#   状态: shared / allowed-idle / unknown / denied / offline
# 模拟器与无线调试设备不出现在这里——它们不参与策略，列出来只会让人误以为可以勾选
status() {
	local online s seen f lbl
	online="$(usb_serials)"
	seen=""

	for s in $online; do
		seen="$seen $s"
		if active_list | grep -qxF -- "$s"; then
			printf '%s\t%s\t%s\n' "$s" "$(label_of "$s")" "shared"
		elif is_allowed "$s"; then
			printf '%s\t%s\t%s\n' "$s" "$(label_of "$s")" "allowed-idle"
		elif is_denied "$s"; then
			printf '%s\t%s\t%s\n' "$s" "$(label_of "$s")" "denied"
		else
			printf '%s\t%s\t%s\n' "$s" "$(label_of "$s")" "unknown"
		fi
	done

	for f in "$ALLOW_DIR"/* "$DENY_DIR"/*; do
		[ -e "$f" ] || continue
		s="$(basename "$f")"
		valid_serial "$s" || continue
		case " $seen " in *" $s "*) continue ;; esac
		seen="$seen $s"
		lbl="$(sanitize_label < "$f" 2>/dev/null || true)"
		[ -n "$lbl" ] || lbl="$s"
		printf '%s\t%s\t%s\n' "$s" "$lbl" "offline"
	done
}

summary() {
	echo "auto=$([ -f "$FLAG" ] && echo on || echo off)"
	echo "relay=$(relay_up && echo up || echo down)"
	# 只数「真的还插着」的设备。拔线后 active 里的记录会残留一小会儿（宽限期、
	# 或等下一次对账），照抄 active 的条数会让菜单栏图标在设备早已拔掉之后
	# 继续显示「共享中」。status 那边本来就把不在线的设备算作 offline，这里要一致。
	local sn=0 ss
	for ss in $(active_list); do
		usb_serials | grep -qxF -- "$ss" && sn=$((sn + 1))
	done
	echo "shared=$sn"
	echo "dns=$(dns_list)"
	echo "ignored=$(ignored_devices | wc -l | tr -d ' ')"
	# 未授权 = 手机上没点「允许 USB 调试」。它和「插着但 adb 读不到」是两回事，
	# 该做的事也完全相反（前者去手机上点，后者换 USB 口），必须分开报
	echo "unauthorized=$(ignored_devices | awk -F'\t' '$2=="unauthorized"{n++} END{print n+0}')"
	# 下载 .app 直接用的人不会先装依赖，界面需要据此引导
	local miss=""
	command -v gnirehtet >/dev/null 2>&1 || miss="gnirehtet"
	command -v adb >/dev/null 2>&1 || miss="${miss:+$miss,}adb"
	echo "deps=${miss:-ok}"
	# 数量而非 yes/no：需要区分「一台卡住」和「三台卡住」
	echo "usb_stuck=$(usb_stuck_count)"
	# 隧道断了但状态还显示「共享中」会误导用户去查手机设置，必须暴露
	local tun="ok" s
	for s in $(active_list); do
		usb_serials | grep -qxF -- "$s" || continue
		tunnel_ok "$s" || tun="broken"
	done
	echo "tunnel=$tun"
	echo "fd_exhausted=$(fd_exhausted && echo yes || echo no)"
	echo "port=$PORT"
	echo "port_conflict=$(port_taken_by_other >/dev/null && echo yes || echo no)"
	# 插线自动共享全靠守护进程。它若不在，界面仍会显示「自动模式已开启」，
	# 用户无从察觉，所以必须暴露出来。
	echo "daemon=$(pgrep -f 'MacToAndroid/watcher.sh' >/dev/null 2>&1 && echo up || echo down)"
}

# 环境自检，供 App 与用户排查
doctor() {
	local apk
	printf 'gnirehtet\t%s\n' "$(command -v gnirehtet 2>/dev/null || echo 未安装)"
	printf 'adb\t%s\n' "$(command -v adb 2>/dev/null || echo 未安装)"
	apk="$(gnirehtet_apk 2>/dev/null || echo 未找到)"
	printf 'apk\t%s\n' "$apk"
	printf 'mac_version\t%s\n' "$(mac_apk_version)"
	printf 'state_dir\t%s\n' "$STATE_DIR"
	# 守护进程启动时落盘的读帧模式。「现在到底走的哪条路」不该只能翻日志
	printf 'framer\t%s\n' "$(cat "$STATE_DIR/framer" 2>/dev/null || echo 未记录)"
	printf 'log_dir\t%s\n' "$LOG_DIR"
	printf 'app_path\t%s\n' "$(cat "$SELF_DIR/app-path" 2>/dev/null || echo 未记录)"
	if port_taken_by_other >/dev/null; then
		printf 'port_%s\t被占用: %s\n' "$PORT" "$(port_taken_by_other | tr '\t' ' ')"
	else
		printf 'port_%s\t可用或由 gnirehtet 持有\n' "$PORT"
	fi
	printf 'port_range\t%s..%s（被占时自动换）\n' "$PORT_BASE" "$((PORT_BASE + PORT_TRIES - 1))"
	printf 'fd_limit\t%s（launchd 默认软上限只有 %s）\n' "$FD_LIMIT" "$(launchctl limit maxfiles 2>/dev/null | awk '{print $2}')"
	if fd_exhausted; then
		printf 'fd\t%s\n' "relay 曾因文件描述符耗尽丢包，心跳会自动重启它"
	fi
	printf 'usb_adb_ifaces\t%s\n' "$(adb_iface_count)"
	printf 'usb_adb_visible\t%s\n' "$(usb_serials | wc -l | tr -d ' ')"
	if usb_stuck; then
		printf 'usb\t%s\n' "有 $(usb_stuck_count) 台设备插着但 adb 读不到（USB 半死，LIBUSB_ERROR_IO）"
		printf 'usb_fix\t%s\n' "拔插该设备，或换一个 USB 口（某些口接触不良会反复触发）；无效则切换手机 USB 模式 / 重开 USB 调试"
	else
		printf 'usb\t%s\n' "正常"
	fi
}

# ---------------------------------------------------------------- 子命令

cmd="${1:-}"

# 会修改状态的子命令统一加锁
case "$cmd" in
	reconcile | health | heal | sync-dns | repair-tunnel | stop-all | allow | deny | unshare | forget | auto | install-client | uninstall-client | push-client | resolve )
		acquire_lock || exit 1
		;;
esac

case "$cmd" in
	status)   status ;;
	ignored)  ignored_devices ;;
	summary)  summary ;;
	doctor)   doctor ;;
	version)  echo "$MTA_VERSION" ;;
	# App 要用 kqueue 盯 changed 文件，路径由这里给，避免它自己拼 TMPDIR
	# （沙盒、不同启动域下 TMPDIR 可能不是同一个）
	state-dir) echo "$STATE_DIR" ;;
	pending)  grep -v '^$' "$PENDING" 2>/dev/null || true ;;
	resolve)
		need_serial "${2:-}"
		grep -vxF -- "$2" "$PENDING" 2>/dev/null > "$PENDING.tmp" || true
		mv "$PENDING.tmp" "$PENDING" 2>/dev/null || true ;;
	allow)
		need_serial "${2:-}"
		rm -f "$DENY_DIR/$2"; remember_model "$ALLOW_DIR" "$2"; reconcile ;;
	deny)
		need_serial "${2:-}"
		rm -f "$ALLOW_DIR/$2"; : >> "$DENY_DIR/$2"; remember_model "$DENY_DIR" "$2"
		client_stop "$2" || true; reconcile ;;
	unshare)
		need_serial "${2:-}"
		rm -f "$ALLOW_DIR/$2"
		# 与 forget 同理：不标记的话紧跟的对账会把它当陌生设备并弹窗，
		# 用户刚点「停止共享」就被追问「要不要共享」
		mark_asked "$2"
		client_stop "$2" || true; reconcile ;;
	forget)
		need_serial "${2:-}"
		rm -f "$ALLOW_DIR/$2" "$DENY_DIR/$2"
		# 关键：标记为「已问过」而不是清掉记录。
		# 否则紧跟的对账会发现它成了陌生设备并立刻弹窗——用户刚点「忘记」
		# 就被追问「要不要共享」，像是应用在跟你对着干。
		# 想重新被询问，把设备拔下再插上即可（prune_asked 会清掉记录）。
		mark_asked "$2"
		client_stop "$2" || true; reconcile ;;
	reconcile) reconcile ;;
	health)   health ;;
	heal)     heal ;;
	sync-dns) sync_dns ;;
	repair-tunnel)
		if [ -n "${2:-}" ]; then
			need_serial "$2"; repair_tunnel "$2"
		else
			for s in $(active_list); do repair_tunnel "$s"; done
		fi ;;
	stop-all) stop_all ;;
	auto)
		case "${2:-}" in
			on)  touch "$FLAG"; stamp; reconcile ;;
			off) rm -f "$FLAG"; : > "$PENDING" 2>/dev/null || true; stop_all; stamp ;;
			*)   die "用法: auto on|off" ;;
		esac ;;
	preflight) preflight "${2:-}" ;;
	client-running)
		need_serial "${2:-}"
		client_running "$2" && echo yes || echo no ;;
	why)              need_serial "${2:-}"; why_blocked "$2" ;;
	last-start)
		# 最后一次 `gnirehtet start` 的回显。引导层靠它认出 WRITE_SECURE_SETTINGS
		need_serial "${2:-}"
		cat "$STATE_DIR/laststart.$2" 2>/dev/null || true ;;
	install-client)   need_serial "${2:-}"; install_client "$2" ;;
	uninstall-client) need_serial "${2:-}"; uninstall_client "$2" ;;
	# 推送和 adb 装都失败时，界面要能把安装包在访达里指给用户
	apk-path)         gnirehtet_apk || { echo "找不到 gnirehtet.apk" >&2; exit 1; } ;;
	push-client)      need_serial "${2:-}"; push_client "$2" ;;
	open-dev-options) need_serial "${2:-}"; open_dev_options "$2" ;;
	open-downloads)   need_serial "${2:-}"; open_downloads "$2" ;;
	*)
		cat >&2 <<USAGE
MacToAndroid 控制器 v$MTA_VERSION

用法: mta-ctl.sh <子命令>

  status              列出参与策略的设备: serial<TAB>标签<TAB>状态
                      状态 ∈ shared / allowed-idle / unknown / denied / offline
  ignored             列出被忽略的设备及原因（模拟器 / 无线调试 / 未授权）
  summary             输出 auto= relay= shared= dns= ignored= port_conflict= 等状态
  doctor              环境自检：依赖、APK 路径、状态目录、端口占用
  reconcile           让实际状态收敛到策略
  health              轻量检查：relay 存活 + 本机 DNS 是否变化
  heal                重新拉起被系统清理掉的 client
  sync-dns            按本机当前 DNS 重新下发给在共享的设备
  repair-tunnel [serial]  重建 adb reverse 隧道（「有 VPN 但没网」时用）
  allow <serial>      允许并立即开始共享
  deny <serial>       拒绝并不再询问
  unshare <serial>    停止共享但不加入拒绝列表（下次连接会重新询问）
  forget <serial>     从允许/拒绝列表中彻底移除（不会立刻重新询问，重插才会）
  pending             列出待询问的陌生设备
  resolve <serial>    从待询问队列移除
  auto on|off         自动模式总开关
  stop-all            停掉所有 client 与 relay
  preflight <serial>  检查单台设备的前置条件
  client-running <serial>   手机端客户端是否真的在运行（yes/no）
  why <serial>        这台设备为什么没在共享（已在共享则输出空）
  last-start <serial> 最后一次 gnirehtet start 的回显（排查拉不起客户端）
  install-client <serial>   在手机上安装 gnirehtet 客户端
  uninstall-client <serial> 卸载手机端客户端（签名不一致时得先卸再装）
  apk-path            输出 gnirehtet.apk 的路径
  push-client <serial>      把 APK 推到手机下载目录（USB 安装被禁时的退路）
  open-dev-options <serial> 打开手机的开发者选项
  open-downloads <serial>   打开手机的「下载」界面（推送 APK 后让用户直接点安装）
  version             输出版本号
  state-dir           易变状态目录（界面用它盯 changed 文件）
USAGE
		exit 1 ;;
esac
