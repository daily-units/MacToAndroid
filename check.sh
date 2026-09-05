#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Waldron
#
# 改完代码随手跑一遍。全部是静态检查 + 只读子命令，不会动任何状态。
#
# 为什么值得有这个脚本：这个项目被咬过好几次的都是**只在某个环境下现形**的问题
# （UTF-8 locale 下 bash 3.2 的变量名解析、界面调了一个不存在的子命令、
# 引导层依赖的中文文案被改掉），它们既不会让 bash -n 失败、也不会让编译报错。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
note() { printf '    %s\n' "$1"; }

SWIFT_SRCS=(MenuBar.swift Window.swift Installer.swift Guide.swift Notify.swift)

echo "shell 语法"
for f in *.sh; do
	if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f"; bash -n "$f" 2>&1 | sed 's/^/    /'; fi
done

echo "python 语法"
if command -v python3 >/dev/null 2>&1; then
	for f in *.py; do
		if python3 -c "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read())" "$f" 2>/dev/null; then
			ok "$f"
		else
			bad "$f"
		fi
	done
else
	note "没有 python3，跳过"
fi

echo "Swift 编译（警告也算不通过——这个项目一直保持零警告）"
if command -v swiftc >/dev/null 2>&1; then
	TMPD="$(mktemp -d)"
	if swiftc -O -parse-as-library -o "$TMPD/out" "${SWIFT_SRCS[@]}" 2>"$TMPD/err"; then
		# grep -c 没匹配时会输出 0 **并且**退出码非 0，所以不能写 `|| echo 0`
		# ——那会在已经输出的 0 后面再追加一个 0，变成 "0\n0"
		n="$(grep -c 'warning:' "$TMPD/err" 2>/dev/null || true)"
		n="${n:-0}"
		if [ "$n" -eq 0 ]; then ok "编译通过，无警告"; else bad "有 $n 条警告"; grep 'warning:' "$TMPD/err" | sed 's/^/    /' | head -10; fi
	else
		bad "编译失败"
		head -20 "$TMPD/err" | sed 's/^/    /'
	fi
	rm -rf "$TMPD"
else
	note "没有 swiftc，跳过"
fi

echo "变量名紧跟全角字符（UTF-8 locale 下 bash 3.2 会报 unbound variable）"
if command -v python3 >/dev/null 2>&1; then
	hits="$(python3 - <<'PY'
import glob, re
pat = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]')
out = []
for f in sorted(glob.glob('*.sh')):
    for i, line in enumerate(open(f, 'rb').read().split(b'\n'), 1):
        if line.lstrip().startswith(b'#'):
            continue
        for m in pat.finditer(line):
            out.append(f"{f}:{i}  {m.group(0).decode('utf-8', 'replace')}")
print("\n".join(out))
PY
)"
	if [ -z "$hits" ]; then ok "无"; else bad "以下位置要改成 \${VAR}"; printf '%s\n' "$hits" | sed 's/^/    /'; fi
fi

echo "界面调用的 mta-ctl 子命令都存在"
if command -v python3 >/dev/null 2>&1; then
	res="$(python3 - <<'PY'
import re
ctl = open('mta-ctl.sh', encoding='utf-8').read()
labels = set()
for m in re.finditer(r'^\s*([a-z][a-z0-9-]*(?:\s*\|\s*[a-z][a-z0-9-]*)*)\s*\)', ctl, re.M):
    labels |= {x.strip() for x in m.group(1).split('|')}
used = set()
for f in ('MenuBar.swift', 'Window.swift', 'Installer.swift', 'Guide.swift', 'Notify.swift'):
    try:
        src = open(f, encoding='utf-8').read()
    except FileNotFoundError:
        continue
    used |= set(re.findall(r'Ctl\.run(?:Discard)?\(\s*\[\s*"([a-z][a-z0-9-]*)"', src))
missing = sorted(used - labels)
print("MISSING " + " ".join(missing) if missing else "OK " + str(len(used)))
PY
)"
	case "$res" in
		OK*) ok "界面用到 ${res#OK } 个子命令，都能对上" ;;
		*)   bad "界面调了不存在的子命令: ${res#MISSING }" ;;
	esac
fi

echo "引导层的判据文案仍与 mta-ctl 一致"
if command -v python3 >/dev/null 2>&1; then
	res="$(python3 - <<'PY'
import re
ctl = open('mta-ctl.sh', encoding='utf-8').read()
guide = open('Guide.swift', encoding='utf-8').read()
# 引导层靠中文子串识别原因，靠 token（ok/restricted/incompatible）识别安装结果。
# mta-ctl 里的文案一改，这里就会静默失配 —— 这是改 UI 时最容易丢的那类联系。
bad = [c for c in re.findall(r'r\.contains\("([^"]+)"\)', guide) if c not in ctl]
bad += [t for t in re.findall(r'out == "([a-z]+)"', guide) if f'echo "{t}"' not in ctl]
print("MISSING " + " | ".join(bad) if bad else "OK")
PY
)"
	case "$res" in
		OK) ok "无漂移" ;;
		*)  bad "以下判据在 mta-ctl.sh 里找不到对应文案: ${res#MISSING }" ;;
	esac
fi

echo "版本号一致"
V1="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build.sh | head -1)"
V2="$(sed -n 's/^MTA_VERSION="\(.*\)"$/\1/p' mta-ctl.sh | head -1)"
if [ -n "$V1" ] && [ "$V1" = "$V2" ]; then ok "build.sh 与 mta-ctl.sh 都是 $V1"; else bad "build.sh=$V1  mta-ctl.sh=$V2"; fi

echo "UTF-8 locale 下的只读子命令冒烟测试"
# 这一项要挡的是「UTF-8 locale 下 bash 自己崩掉」，不是「依赖没装」。两者都返回非 0，
# 但形态不同：bash 的报错带行号（./mta-ctl.sh: line 202: APP?: unbound variable），
# 而依赖缺失是脚本自己打印的干净消息（找不到 gnirehtet.apk）。所以按 stderr 区分。
#
# 早期版本只看退出码，结果 CI 上必挂：runner 不装 gnirehtet，apk-path 如实返回 1,
# 被当成 locale 问题拒绝出包，release.sh 停在源码检查那一步。
# 而这个失败在本机怎么都复现不出来——mta-ctl 第 30 行起**自己重建 PATH**
# （launchd 给的 PATH 太干净，必须这么做），调用方的 PATH 根本不参与，
# 所以「把 brew 从 PATH 里摘掉」从原理上就不是有效对照。踩过。
for sub in version state-dir apk-path summary status ignored doctor; do
	err="$(LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ./mta-ctl.sh "$sub" 2>&1 >/dev/null)"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		ok "mta-ctl $sub"
	elif printf '%s' "$err" | grep -qE 'unbound variable|syntax error|bad substitution|: line [0-9]+:'; then
		bad "mta-ctl $sub 在 UTF-8 locale 下触发了 shell 错误"
		printf '%s\n' "$err" | head -3 | sed 's/^/    /'
	else
		note "mta-ctl $sub 返回 ${rc}：$(printf '%s' "$err" | head -1)（依赖缺失一类，不算不通过）"
	fi
done

echo
if [ "$fail" -eq 0 ]; then echo "全部通过"; else echo "有检查未通过"; fi
exit "$fail"
