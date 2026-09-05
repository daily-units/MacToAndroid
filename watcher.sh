#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Waldron
# MacToAndroid — 守护进程
#
# 只负责监听设备事件并触发对账，所有策略在 mta-ctl.sh 里，App 用的是同一份逻辑。
#
# 事件驱动：adb track-devices 是流式的，设备状态变化时推一条，中间阻塞，不轮询。
# 它的输出形如 "00101a2b3c4d<TAB>device"，前 4 位是十六进制长度前缀而非序列号的一部分，
# 所以这里不解析内容，只把它当作「状态变了」的信号，让 mta-ctl 用 adb devices 取权威列表。
#
# **不能用 read 的返回码区分「超时」和「EOF」。** macOS 的 /bin/bash 是 3.2.57，
# 它的 `read -t` 超时返回 **1**；返回值 >128 是 bash 4.0 以后才有的约定。
# 早期版本写的是 `elif [ "$rc" -gt 128 ]` 当心跳、else 当 EOF —— 结果心跳分支永不成立，
# 每次心跳都被当成 EOF 走了 break。而且当时 read 跑在管道右侧的子 shell 里，
# 子 shell 一 break 就退出，父进程接着 wait 左边的 adb track-devices ——
# 它空闲时永远不会退出（只有下次写管道拿到 EPIPE 才死），于是父进程卡在 wait 里，
# 连「track-devices 中断」那行日志都到不了：守护进程在最后一次设备事件之后
# 约 HEARTBEAT 秒就彻底静默，health / heal 一次都不会跑。
# 插拔却仍然「看起来正常」——插线时 adb 写管道拿到 EPIPE 而死，父进程的 wait 才返回，
# 重连后首帧就是权威列表，照样对上一次账。所以这个故障能长期不被发现。
#
# 现在的写法：adb 写进一个 FIFO，读端在主 shell 里（不再有子 shell），
# 超时与 EOF 用 `kill -0 $adb_pid` 区分，与 bash 版本无关。

set -u

# LaunchAgent 的 PATH 很干净，需要自己补上包管理器的位置。
# 不写死 /opt/homebrew：Intel Mac 的 Homebrew 在 /usr/local。
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
for p in /opt/homebrew/bin /usr/local/bin /opt/local/bin "$HOME/.local/bin"; do
	[ -d "$p" ] && PATH="$p:$PATH"
done
export PATH

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTL="$SELF_DIR/mta-ctl.sh"

LOG_DIR="$HOME/Library/Logs/MacToAndroid"
WATCH_LOG="$LOG_DIR/watcher.log"

# 事件管道。放 $TMPDIR（每用户独立、开机清空），和 mta-ctl 的状态目录同一处；
# 带上 pid，避免同一用户下两个实例互相抢同一个管道。
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
FIFO="$STATE_DIR/events.$$"     # 读帧器（或 adb）→ 本进程
RAW="$STATE_DIR/raw.$$"         # adb → 读帧器（仅读帧模式用）
STAMP="$STATE_DIR/changed"      # 状态变化戳，App 用 kqueue 盯着它
LOG_MAX=200000
LOG_KEEP=100000

# 心跳间隔。隧道可能在没有任何设备事件的情况下断掉（例如 adb server 被别的
# 工具重启），只能靠心跳发现。60 秒太久——那段时间手机完全没网且看不出原因，
# 而一次检查只是几十毫秒，所以缩短到 20 秒。
HEARTBEAT=20
HEARTBEAT_BUSY=5        # 仅「无读帧器 + 正在共享」时用：那种组合下拔掉最后一台没有事件
HEAL_INTERVAL=300       # client 自愈的间隔（秒）。按时间算，不按心跳次数——
                        # 心跳间隔是可变的，按次数算会让自愈频率跟着漂
BACKOFF_MAX=60          # adb 异常时的最大重试间隔

# 读帧器「连续短命」就整会话降级。启动自检拦得住「一上来就坏」，拦不住
# 「自检过了、遇到真实数据才退」——比如 adb 换了帧格式，帧尾校验每次都触发。
# 那种情况的表现是每 3~60 秒重连一次，永远好不了。降级成直接读虽然会丢
# 「拔掉最后一台」那个事件（有心跳兜），但不会陷在重连循环里。
FRAMER_FAIL_MAX=3
FRAMER_MIN_LIFE=5       # 读端存活不足这么多秒就算一次「短命」

# adb track-devices 的帧是「4 位十六进制长度 + 该长度的负载」。设备列表为空时长度是 0，
# 那一帧就是 4 个字节 "0000"、**没有换行**——bash 的按行 read 凑不出一行，
# 超时（bash 3.2 上返回 1）还会把这半行丢掉，于是「拔掉最后一台」完全没有事件。
#
# 这个读帧器把每一帧变成一行，空列表帧也就成了正常事件。
# 它**只输出长度**，不输出负载：下游照旧不解析内容，只当「状态变了」的信号。
# 长度离谱（>64KB）时直接退出，让上层重连而不是在错位的流上一直读下去。
FRAMER_PROG='
$| = 1;
while (1) {
    my $head = "";
    while (length($head) < 4) {
        my $chunk;
        my $n = read(STDIN, $chunk, 4 - length($head));
        exit 0 if !defined($n) || $n == 0;
        $head .= $chunk;
    }
    my $len = hex($head);
    exit 0 if $len > 65536;
    my $payload = "";
    while (length($payload) < $len) {
        my $chunk;
        my $n = read(STDIN, $chunk, $len - length($payload));
        exit 0 if !defined($n) || $n == 0;
        $payload .= $chunk;
    }
    # 非空负载必然以换行结尾（每台设备一行 "serial<TAB>state\n"）。不是的话说明
    # 长度读错、流已经错位——立刻退出让上层重连，别在错位的流上继续读下去。
    exit 0 if $len > 0 && substr($payload, -1) ne "\n";
    print "$len\n";
}
'
# perl 是 Apple 捆绑的运行时，已被标记为 deprecated——不在就退回直接读。
# MTA_NO_FRAMER=1 可以强制走回退路径（那条路径没人跑就会腐烂，要能测）。
# 写端退出时补的一行。我们用 <> 打开 FIFO（自己也算写端），所以永远收不到 EOF——
# 没有哨兵就只能等下一次读超时（最长一个心跳）才发现 adb / 读帧器已经死了。
# 读帧器只输出数字，adb 的设备行是 "serial<TAB>state"，都不会撞上这个串。
SENTINEL="__mta_writers_gone__"

FRAMER=""
if [ -z "${MTA_NO_FRAMER:-}" ] && [ -x /usr/bin/perl ]; then
	FRAMER=/usr/bin/perl
fi

# C: 启动自检。喂一个已知向量（一帧 "ab\n" + 一帧空列表），对不上就退回直接读。
# 意义在于：读帧器坏掉（perl 被换、程序在未来版本上行为变了）应该在启动时就发现并降级，
# 而不是带着一个坏的读帧器跑——那会变成「事件全都收不到」这种最难查的故障。
framer_ok() {
	[ "$(printf '0003ab\n0000' | "$FRAMER" -e "$FRAMER_PROG" 2>/dev/null | tr '\n' ' ')" = "3 0 " ]
}

umask 077
mkdir -p "$LOG_DIR" 2>/dev/null
mkdir -p "$STATE_DIR" 2>/dev/null && chmod 700 "$STATE_DIR" 2>/dev/null

log() { echo "$(date '+%F %T') $*" >> "$WATCH_LOG" 2>/dev/null || true; }

trim_log() {
	local sz
	sz="$(stat -f%z "$WATCH_LOG" 2>/dev/null || echo 0)"
	[ "$sz" -le "$LOG_MAX" ] && return 0
	# 原地截断而不是 mv，理由同 mta-ctl 那边：mv 之后持有旧 fd 的进程会继续往
	# 被 unlink 的 inode 里写，日志从此静默冻结。今天 log() 每次都 >> 重新打开、
	# 本来是安全的，保持一致是为了以后有人把长跑进程的输出接到这里时不踩坑。
	tail -c "$LOG_KEEP" "$WATCH_LOG" > "$WATCH_LOG.tmp" 2>/dev/null || return 0
	cat "$WATCH_LOG.tmp" > "$WATCH_LOG" 2>/dev/null
	rm -f "$WATCH_LOG.tmp"
	log "日志已截断"
}

if [ ! -x "$CTL" ]; then
	log "找不到核心控制器: $CTL —— 请重新运行 build.sh"
	sleep 30            # 配合 plist 的 ThrottleInterval，避免疯狂重启
	exit 1
fi

if ! command -v adb >/dev/null 2>&1; then
	log "adb 不在 PATH 中，无法监听设备。请安装 android-platform-tools"
	sleep 30
	exit 1
fi

# 记下 adb 版本：track-devices 是较新的 host 服务，旧 adb 上会立刻 EOF，
# 表现为「反复重连」而看不出原因
if [ -n "$FRAMER" ] && ! framer_ok; then
	log "读帧器自检未通过，退回直接读（拔掉最后一台将靠心跳发现）"
	FRAMER=""
fi
# 模式落盘，doctor 能看到——「现在到底走的哪条路」不该只能翻日志
[ -n "$FRAMER" ] && echo perl > "$STATE_DIR/framer" 2>/dev/null || echo direct > "$STATE_DIR/framer" 2>/dev/null

log "守护进程启动 (ctl v$("$CTL" version 2>/dev/null || echo '?'), $(adb --version 2>/dev/null | head -1), 读帧=$([ -n "$FRAMER" ] && echo perl || echo direct))"
trim_log
# 开机时可能已经插着设备，先对一次账
"$CTL" reconcile || true

adb_pid=""
framer_pid=""
reader_started=0

cleanup() {
	# 同样先 adb 后读帧器，理由见 stop_reader
	[ -n "$adb_pid" ] && kill "$adb_pid" 2>/dev/null
	[ -n "$framer_pid" ] && kill "$framer_pid" 2>/dev/null
	rm -f "$FIFO" "$RAW"
	return 0
}
# launchctl bootout 会发 TERM：顺手带走子进程，别留孤儿
trap 'cleanup; exit 0' TERM INT
trap 'cleanup' EXIT

# 崩溃留下的管道节点（我们不提前 unlink——读帧器要按路径打开它）
rm -f "$STATE_DIR"/events.* "$STATE_DIR"/raw.* 2>/dev/null

# 写端是否还活着。**不能用 read 的返回码判 EOF**（见文件头），只能问进程。
writers_alive() {
	[ -n "$adb_pid" ] && kill -0 "$adb_pid" 2>/dev/null || return 1
	[ -z "$framer_pid" ] || kill -0 "$framer_pid" 2>/dev/null || return 1
	return 0
}

stop_reader() {
	local i
	exec 7<&- 2>/dev/null || true
	# 顺序要紧：先杀 adb，读帧器的 stdin 一 EOF 它就自己退、外层 subshell 随之结束。
	# 反过来直接杀那个 subshell，会把 perl 留成孤儿（它还持着 RAW 和 FIFO）。
	[ -n "$adb_pid" ] && kill "$adb_pid" 2>/dev/null
	if [ -n "$framer_pid" ]; then
		for i in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$framer_pid" 2>/dev/null || break
			sleep 0.1
		done
		kill "$framer_pid" 2>/dev/null
	fi
	[ -n "$adb_pid" ] && wait "$adb_pid" 2>/dev/null
	[ -n "$framer_pid" ] && wait "$framer_pid" 2>/dev/null
	adb_pid=""; framer_pid=""
	rm -f "$FIFO" "$RAW"
	return 0
}

# 拉起 adb（读帧模式下再串一个读帧器），并把读端挂到 fd 7 上。
# 所有会阻塞的 open 都发生在后台进程里，本进程用 <> 打开不阻塞。
start_reader() {
	rm -f "$FIFO" "$RAW"
	mkfifo "$FIFO" 2>/dev/null || return 1
	if [ -n "$FRAMER" ]; then
		mkfifo "$RAW" 2>/dev/null || return 1
		adb track-devices > "$RAW" 2>/dev/null &
		adb_pid=$!
		# 外面套一层：读帧器退出后补一行哨兵，读循环就能立刻知道写端没了。
		# adb 不用套——它死了读帧器会读到 EOF 而退出，一样走到哨兵。
		( "$FRAMER" -e "$FRAMER_PROG" < "$RAW" 2>/dev/null; printf '%s\n' "$SENTINEL" ) > "$FIFO" &
		framer_pid=$!
	else
		( adb track-devices 2>/dev/null; printf '%s\n' "$SENTINEL" ) > "$FIFO" &
		adb_pid=$!
		framer_pid=""
	fi
	exec 7<> "$FIFO"
	reader_started="$(date +%s)"
	return 0
}

backoff=3
last_heal="$(date +%s)"
framer_fails=0
while true; do
	if ! start_reader; then
		# 建不出管道就退化成纯轮询。宁可慢，也不能一声不响地什么都不做
		log "无法创建事件管道，本轮退化为轮询"
		"$CTL" health || true
		sleep "$HEARTBEAT"
		continue
	fi
	while true; do
		hb="$HEARTBEAT"
		# 没有读帧器时，「拔掉最后一台」不产生事件（空列表帧没换行），只能靠心跳发现。
		# 正在共享就把心跳压短一点，让状态早点收敛；空闲时没必要。
		if [ -z "$FRAMER" ] && [ -s "$STATE_DIR/active" ]; then hb="$HEARTBEAT_BUSY"; fi
		_line=""
		IFS= read -r -u 7 -t "$hb" _line
		rc=$?
		if [ "$_line" = "$SENTINEL" ]; then
			# 写端退出时补的那一行：立刻重连，不用等 writers_alive 在下一次超时里发现
			break
		fi
		if [ "$rc" -eq 0 ] || [ -n "$_line" ]; then
			# 先打状态戳再对账：界面几百毫秒内就能跟上，不用等对账跑完（可能几秒）
			date +%s > "$STAMP" 2>/dev/null || true
			# 拿到完整一行 = 设备事件。
			# `-n "$_line"` 是给 bash 4+ 留的：拔掉最后一台时 adb 只发不带换行的
			# "0000"（空列表），bash 4+ 超时会把这半行留在变量里，据此也能当事件处理；
			# bash 3.2 超时会丢掉半行数据，那种情况由 mta-ctl 的 health 兜
			# （它会检查「共享列表里的设备是否还在线」）。
			log "设备状态变化"
			trim_log
			"$CTL" reconcile || true
		elif writers_alive; then
			# 写端还活着 → 这次 read 返回是超时，也就是心跳。
			# bash 3.2 返回 1、bash 4+ 返回 >128，两边都落在这里。
			"$CTL" health || true
			now="$(date +%s)"
			if [ $((now - last_heal)) -ge "$HEAL_INTERVAL" ]; then
				last_heal="$now"
				"$CTL" heal || true
			fi
		else
			break        # adb / 读帧器真的退了（adb server 挂了）
		fi
	done
	stop_reader

	# 读帧器连续短命 → 整会话降级
	if [ -n "$FRAMER" ]; then
		if [ $(( $(date +%s) - reader_started )) -lt "$FRAMER_MIN_LIFE" ]; then
			framer_fails=$((framer_fails + 1))
			if [ "$framer_fails" -ge "$FRAMER_FAIL_MAX" ]; then
				log "读帧器连续 $framer_fails 次刚启动就退出，本会话改用直接读"
				FRAMER=""
				echo direct > "$STATE_DIR/framer" 2>/dev/null || true
				framer_fails=0
			fi
		else
			framer_fails=0
		fi
	fi

	log "track-devices 中断，${backoff} 秒后重连"
	sleep "$backoff"
	# 指数退避：adb 长期不可用时不要每 3 秒刷一条日志
	backoff=$((backoff * 2))
	[ "$backoff" -gt "$BACKOFF_MAX" ] && backoff=$BACKOFF_MAX
	# 只要能恢复一次就把退避重置，下次故障仍然快速重连
	if adb devices >/dev/null 2>&1; then backoff=3; fi
done
