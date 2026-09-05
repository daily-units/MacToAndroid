#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Waldron
#
# 打发布包：通用二进制 → ditto 压缩 → 校验和 → 发布说明（可选直接发到 GitHub Release）
#
# 用法:
#   ./release.sh              只出包，打印后续命令
#   ./release.sh --publish    额外调 gh 创建 GitHub Release 并上传附件
#
# 为什么不用 zip 而用 ditto：zip 不保留扩展属性和符号链接，.app 压完再解开签名会坏掉，
# 对方双击时报的是「应用程序已损坏」——比「无法验证开发者」更难查。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DIST="$SCRIPT_DIR/dist"
APP="$DIST/MacToAndroid.app"

PUBLISH=0
[ "${1:-}" = "--publish" ] && PUBLISH=1

# ---------------------------------------------------------------- 版本一致性

# 版本号写在两个地方（build.sh 打进 Info.plist，mta-ctl 自己 report），
# 对不上会让 doctor 和 App 显示的版本互相矛盾，发版前先卡住
VERSION="$(sed -n 's/^VERSION="\(.*\)"$/\1/p' build.sh | head -1)"
CTL_VERSION="$(sed -n 's/^MTA_VERSION="\(.*\)"$/\1/p' mta-ctl.sh | head -1)"
[ -n "$VERSION" ] || { echo "读不出 build.sh 里的 VERSION" >&2; exit 1; }
if [ "$VERSION" != "$CTL_VERSION" ]; then
	echo "版本号不一致: build.sh=$VERSION  mta-ctl.sh=$CTL_VERSION" >&2
	exit 1
fi
echo "版本 $VERSION"

# ---------------------------------------------------------------- 源码层检查

# 源码层的门槛统一交给 check.sh，避免两处各写一份扫描然后慢慢漂移
if [ -x ./check.sh ]; then
	echo "源码检查:"
	./check.sh | sed 's/^/  /' || { echo "check.sh 未通过，停止出包" >&2; exit 1; }
else
	echo "! 找不到 check.sh，跳过源码层检查" >&2
fi

# ---------------------------------------------------------------- 构建

rm -rf "$DIST"
mkdir -p "$DIST"
./build.sh --no-install "$DIST" >/dev/null
[ -d "$APP" ] || { echo "构建失败: 没有生成 $APP" >&2; exit 1; }

# ---------------------------------------------------------------- 出包前的检查

fail=0
check() {  # check <说明> <条件命令...>
	local msg="$1"; shift
	if "$@" >/dev/null 2>&1; then
		printf '  ✓ %s\n' "$msg"
	else
		printf '  ✗ %s\n' "$msg"; fail=1
	fi
}
echo "产物检查:"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/MacToAndroid" 2>/dev/null || echo '')"
case "$ARCHS" in
	*arm64*x86_64* | *x86_64*arm64* ) printf '  ✓ 通用二进制 (%s)\n' "$ARCHS" ;;
	* ) printf '  ✗ 不是通用二进制 (%s) —— Intel Mac 会打不开\n' "$ARCHS"; fail=1 ;;
esac
check "签名有效"          codesign -v "$APP"
check "带 mta-ctl.sh"     test -f "$APP/Contents/Resources/mta-ctl.sh"
check "带 watcher.sh"     test -f "$APP/Contents/Resources/watcher.sh"
# 卸载脚本必须在包里：只下载 .app 的人否则没有任何卸载手段，
# 而拖进废纸篓不会带走那两个 LaunchAgent
check "带 uninstall.sh"   test -x "$APP/Contents/Resources/uninstall.sh"
check "带 LICENSE"        test -f "$APP/Contents/Resources/LICENSE"
check "带 NOTICE"         test -f "$APP/Contents/Resources/NOTICE"
check "无写死的用户路径"   bash -c '! grep -rqI "/Users/" "$0/Contents/MacOS" "$0/Contents/Resources"' "$APP"

[ "$fail" -eq 0 ] || { echo "检查未通过，停止出包" >&2; exit 1; }

# ---------------------------------------------------------------- 压缩与校验

ZIP="$DIST/MacToAndroid-$VERSION.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 解开再验一次签名：确认压缩没破坏包结构（这正是 zip 会踩的坑）
VERIFY="$(mktemp -d)"
trap 'rm -rf "$VERIFY"' EXIT
ditto -x -k "$ZIP" "$VERIFY"
if codesign -v "$VERIFY/MacToAndroid.app" >/dev/null 2>&1; then
	echo "  ✓ 压缩包解开后签名依然有效"
else
	echo "  ✗ 解压后签名坏了，别发" >&2; exit 1
fi

# 打完包就把解开的 .app 删掉：它和 /Applications 里那份是同一个 bundle id，
# 用户要是双击了它，登录项会被改指向 dist/——而下次 release.sh 会把 dist 整个删掉，
# 于是开机自启静默失效。留 zip 就够了。
rm -rf "$APP"

SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
SIZE="$(du -h "$ZIP" | cut -f1 | tr -d ' ')"

# ---------------------------------------------------------------- 发布说明

NOTES="$DIST/RELEASE-NOTES.md"
cat > "$NOTES" <<EOF
## 安装

**1. 先装两个依赖**

\`\`\`
brew install gnirehtet
brew install --cask android-platform-tools
\`\`\`

**2. 解压后把 MacToAndroid.app 拖进「应用程序」**

这个 App 只做了 ad-hoc 签名、没有经过 Apple 公证（公证需要每年 99 美元的开发者账号），
所以首次打开会被系统拦下，提示「无法打开，因为无法验证开发者」。

最省事的做法是先去掉隔离标记再打开：

\`\`\`
xattr -dr com.apple.quarantine "/Applications/MacToAndroid.app"
\`\`\`

不想用终端的话：双击一次让它被拦下，然后到
**系统设置 → 隐私与安全性**，在下方找到被拦的提示，点「仍要打开」。
（macOS 15 起 Apple 去掉了「右键 → 打开」这条绕过路径，旧教程里的说法在新系统上不再适用。）

**3. 打开后菜单栏出现图标**，脚本与登录项会自动铺开，不需要跑任何安装脚本。
手机端要开的三个开关见 README。

## 校验

\`\`\`
shasum -a 256 MacToAndroid-$VERSION.zip
\`\`\`

\`\`\`
$SHA
\`\`\`

通用二进制（${ARCHS}），最低 macOS 13。
EOF

# ---------------------------------------------------------------- Homebrew Cask

# 版本号和 sha256 自动填进去——手抄这两样是最容易出错的一步，
# 而 cask 的 sha256 错了用户侧直接装不上。
REPO="${MTA_REPO:-}"
if [ -z "$REPO" ]; then
	REPO="$(git remote get-url origin 2>/dev/null | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##' || true)"
fi
REPO_KNOWN=1
if [ -z "$REPO" ]; then
	REPO="OWNER/MacToAndroid"
	REPO_KNOWN=0
fi

CASK="$DIST/mactoandroid.rb"
cat > "$CASK" <<EOF
cask "mactoandroid" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/MacToAndroid-#{version}.zip"
  name "MacToAndroid"
  desc "Reverse tethering for Android devices over USB"
  homepage "https://github.com/$REPO"

  depends_on formula: "gnirehtet"
  depends_on cask: "android-platform-tools"
  depends_on macos: :ventura

  app "MacToAndroid.app"

  # 首次运行时 App 会自己铺开脚本并注册两个 LaunchAgent。
  # macOS 对 LaunchAgent 没有任何自动清理机制，所以卸载必须显式写出来——
  # 否则删掉 .app 之后守护进程还会继续开机自启、继续共享。
  uninstall launchctl: [
              "com.local.mactoandroid",
              "com.local.mactoandroid.menubar",
            ],
            quit:      "com.local.mactoandroid.app",
            trash:     [
              "~/Library/Application Support/MacToAndroid",
              "~/Library/LaunchAgents/com.local.mactoandroid.menubar.plist",
              "~/Library/LaunchAgents/com.local.mactoandroid.plist",
            ]

  # 用户数据留给 --zap
  zap trash: [
    "~/.config/mactoandroid",
    "~/Library/Logs/MacToAndroid",
    "~/Library/Logs/MacToAndroid-uninstall.log",
  ]

  caveats <<~CAVEATS
    本应用只做了 ad-hoc 签名、未经 Apple 公证，而 Homebrew 默认会给下载的应用
    加隔离标记，所以首次打开仍会被 Gatekeeper 拦下。去掉标记即可：

      xattr -dr com.apple.quarantine "#{appdir}/MacToAndroid.app"

    也可以安装时就不加：brew install --cask --no-quarantine mactoandroid

    首次运行会注册两个后台登录项（守护进程、菜单栏自启），
    macOS 会各弹一次「App Background Activity」通知，属正常。

    手机端客户端不在 Homebrew 管理范围内，需要时自己卸：
      adb uninstall com.genymobile.gnirehtet
  CAVEATS
end
EOF

echo
echo "已生成:"
echo "  $CASK"
echo "  $ZIP  ($SIZE)"
echo "  $NOTES"
echo "  sha256 $SHA"

# ---------------------------------------------------------------- 发布

if [ "$PUBLISH" -eq 1 ]; then
	command -v gh >/dev/null 2>&1 || { echo "没装 gh: brew install gh" >&2; exit 1; }
	gh auth status >/dev/null 2>&1 || { echo "gh 未登录: gh auth login" >&2; exit 1; }
	# cask 跟着 zip 一起挂上去：它的 sha256 只对得上这一次构建出的这个 zip，
	# 事后重新生成的那份对应的是另一个二进制，用户 brew install 会卡在校验失败上。
	gh release create "v$VERSION" "$ZIP" "$CASK" --title "MacToAndroid $VERSION" --notes-file "$NOTES"
	echo "已发布 v$VERSION"
else
	echo
	if [ "$REPO_KNOWN" -eq 0 ]; then
		echo "! 没检测到 GitHub 仓库，cask 里的地址是占位符 $REPO"
		echo "  设 MTA_REPO=用户名/仓库名 再跑一次，或手改 $CASK"
		echo
	fi
	echo "Homebrew Cask（自建 tap，一次性准备）："
	echo "  1) 建一个名为 homebrew-mactoandroid 的仓库（brew 要求 tap 仓库以 homebrew- 开头）"
	echo "  2) 把 $CASK 放到该仓库的 Casks/mactoandroid.rb"
	echo "  之后每次发版重复第 2 步再提交即可——版本号和 sha256 已经填好"
	echo
	echo "  用户侧："
	echo "    brew tap ${REPO%%/*}/mactoandroid"
	echo "    brew trust ${REPO%%/*}/mactoandroid       # 新版 brew 不加载未信任 tap 的 cask"
	echo "    brew install --cask --no-quarantine mactoandroid"
	echo "    brew uninstall --zap mactoandroid       # 连配置和日志一起清"
	echo
	echo "发布到 GitHub Release："
	echo "  gh release create v$VERSION \"$ZIP\" \"$CASK\" --title \"MacToAndroid $VERSION\" --notes-file \"$NOTES\""
	echo "或在网页 Releases → Draft a new release 里把 zip 和 mactoandroid.rb 拖进附件。"
	echo "（cask 一起挂上去：它的 sha256 只对得上这一次构建出的这个 zip）"
fi
