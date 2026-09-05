#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Waldron
# 卸载 MacToAndroid
# 用法: ./uninstall.sh [--purge] [--yes] [--app-dir DIR]
#   --purge        同时删除配置目录与日志，并卸载手机端客户端
#   --yes          不询问，直接执行
#   --app-dir DIR  App 装在非 /Applications 时指定
set -uo pipefail

LABEL="com.local.mactoandroid"
MENU_LABEL="com.local.mactoandroid.menubar"
BUNDLE_MENU="com.local.mactoandroid.app"
RUNTIME_DIR="$HOME/Library/Application Support/MacToAndroid"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONF_DIR="$HOME/.config/mactoandroid"
LOG_DIR="$HOME/Library/Logs/MacToAndroid"
# 与 mta-ctl 用同一份解析：TMPDIR 在 SSH / cron 里可能是空的，
# ${TMPDIR:-/tmp} 的兜底会让状态落到所有用户可写的 /tmp，还和守护进程分叉成两份。
# getconf DARWIN_USER_TEMP_DIR 给的就是 launchd 那个每用户目录。
_state_root="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
case "$_state_root" in
	/*) _state_root="${_state_root%/}" ;;
	*)  case "${TMPDIR:-}" in
		/*) _state_root="${TMPDIR%/}" ;;
		*)  echo "拿不到每用户临时目录" >&2; exit 1 ;;
	esac ;;
esac
STATE_DIR="$_state_root/MacToAndroid"
PKG="com.genymobile.gnirehtet"

# relay 未必在默认端口上：31416 被占时 mta-ctl 会在 31416..31425 里自动换一个。
# 只看 31416 的话，relay 跑在 31417 上时「残留检查」会报告「干净」而其实没清掉。
# 整个范围一起扫，不依赖状态目录里的 port 文件（那个文件本来就要被删掉）。
PORT_BASE=31416
PORT_TRIES=10
PORTS=""
i=0
while [ "$i" -lt "$PORT_TRIES" ]; do
	PORTS="$PORTS $((PORT_BASE + i))"
	i=$((i + 1))
done

# 只认「本用户的 gnirehtet」：同一台机器上别的用户也可能在跑，那个既不该杀也杀不掉
our_gnirehtet() {
	local pid="$1" comm owner
	comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
	owner="$(ps -o uid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
	case "$comm" in *gnirehtet* ) [ "$owner" = "$(id -u)" ] && return 0 ;; esac
	return 1
}

gnirehtet_pids() {
	local port p
	for port in $PORTS; do
		for p in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null); do
			our_gnirehtet "$p" && echo "$p	$port"
		done
	done
}

PURGE=0
ASSUME_YES=0
APP_DIR="/Applications"

while [ $# -gt 0 ]; do
	case "$1" in
		--purge) PURGE=1; shift ;;
		--yes|-y) ASSUME_YES=1; shift ;;
		--app-dir) APP_DIR="${2:-}"; shift 2 ;;
		*) echo "未知参数: $1" >&2; exit 1 ;;
	esac
done

# 构建时记下的绝对路径最准，优先用它
APP=""
if [ -r "$RUNTIME_DIR/app-path" ]; then
	APP="$(cat "$RUNTIME_DIR/app-path" 2>/dev/null || true)"
fi
[ -n "$APP" ] && [ -d "$APP" ] || APP="$APP_DIR/MacToAndroid.app"

case "$APP" in
	"" | "/" | "/Applications" ) echo "App 路径不合法: '$APP'" >&2; exit 1 ;;
esac

echo "将执行："
echo "  • 停止所有共享与守护进程"
echo "  • 删除 $PLIST"
echo "  • 删除 $RUNTIME_DIR"
echo "  • 删除 $APP"
echo "  • 删除 $STATE_DIR"
if [ "$PURGE" -eq 1 ]; then
	echo "  • 删除 ${CONF_DIR}（设备允许/拒绝列表）"
	echo "  • 删除 $LOG_DIR"
	echo "  • 卸载手机端 $PKG"
fi
echo "  （不会动源码目录，也不会卸载 gnirehtet / adb）"
echo

if [ "$ASSUME_YES" -eq 0 ]; then
	printf "继续？[y/N] "
	read -r ans
	case "$ans" in y|Y|yes|YES) ;; *) echo "已取消"; exit 0 ;; esac
fi

for p in /opt/homebrew/bin /usr/local/bin /opt/local/bin; do
	[ -d "$p" ] && PATH="$p:$PATH"
done
export PATH

# 先让控制器把所有 client 与 relay 停干净，趁 adb 还通
if [ -x "$RUNTIME_DIR/mta-ctl.sh" ]; then
	"$RUNTIME_DIR/mta-ctl.sh" stop-all >/dev/null 2>&1 || true
fi

# 先让前端退出，再卸 agent，避免残留进程占着 bundle id
osascript -e "tell application id \"$BUNDLE_MENU\" to quit" >/dev/null 2>&1 || true
pkill -f "/MacToAndroid.app/Contents/MacOS/" 2>/dev/null || true
# App 派生出来的 ctl（比如正在跑的 install-client，最长 180 秒）不会随它一起死。
# 那个孤儿之后任何一步都会 mkdir -p 状态目录，于是刚删掉的目录又回来了。
pkill -f "$RUNTIME_DIR/mta-ctl.sh" 2>/dev/null || true

launchctl bootout "gui/$UID/$MENU_LABEL" 2>/dev/null || true
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$MENU_LABEL.plist"
pkill -f "$RUNTIME_DIR/watcher.sh" 2>/dev/null || true

# 只杀确认是 gnirehtet 的进程，端口可能被别的程序占着
gnirehtet_pids | while IFS='	' read -r p port; do
	[ -n "$p" ] || continue
	kill -9 "$p" 2>/dev/null || true
done

rm -f "$PLIST"
rm -rf "$RUNTIME_DIR" "$APP" "$STATE_DIR"

if [ "$PURGE" -eq 1 ]; then
	rm -rf "$CONF_DIR" "$LOG_DIR"
	if command -v adb >/dev/null 2>&1; then
		# 必须逐台带 -s：插着两台时光跑 `adb uninstall` 会报 more than one device
		devs="$(adb devices 2>/dev/null | tail -n +2 | awk '$2=="device"{print $1}')"
		if [ -z "$devs" ]; then
			echo "手机端客户端未卸载（没有在线设备）"
		else
			for d in $devs; do
				adb -s "$d" uninstall "$PKG" >/dev/null 2>&1 \
					&& echo "手机端客户端已从 $d 卸载" \
					|| echo "$d 上的手机端客户端未卸载（可能本来就没装）"
			done
		fi
	fi
fi

echo
echo "已卸载。残留检查："
leftover=0
while IFS='	' read -r p port; do
	[ -n "$p" ] || continue
	echo "  ! 仍有 gnirehtet 占用端口 $port (pid $p)"
	leftover=1
done <<EOF
$(gnirehtet_pids)
EOF
[ "$leftover" -eq 0 ] && echo "  端口 ${PORT_BASE}..$((PORT_BASE + PORT_TRIES - 1)) 无 gnirehtet 残留"
pgrep -f 'MacToAndroid/watcher.sh' >/dev/null 2>&1 && echo "  ! 守护进程仍在运行" || echo "  守护进程已停止"
launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 && echo "  ! LaunchAgent 仍已加载" || echo "  LaunchAgent 已卸载"
[ -d "$APP" ] && echo "  ! App 仍存在: $APP" || echo "  App 已删除"
launchctl print "gui/$UID/$MENU_LABEL" >/dev/null 2>&1 && echo "  ! 登录项仍已加载" || echo "  登录项已卸载"
if [ -d "$STATE_DIR" ]; then
	echo "  ! 状态目录被重建: ${STATE_DIR}（有 ctl 进程在收尾，重启会清空）"
else
	echo "  状态目录已删除"
fi
