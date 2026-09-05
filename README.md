# MacToAndroid

把 Mac 的网络通过 USB 数据线反向共享给 Android 设备（reverse tethering），基于
[gnirehtet](https://github.com/Genymobile/gnirehtet)。

方向和常见的「手机热点给电脑」相反：**Mac 上网 → Android 借网**。支持同时给多台设备共享。

## 为什么需要它

macOS 的「互联网共享」不支持 Wi-Fi 连网时再用 Wi-Fi 共享（同一块网卡不能同时做
station 和 AP），可选的下游只有以太网和雷雳。而 Android 只能把自己的网络共享**出去**，
没有「通过 USB 接受电脑网络」的开关——USB 是主从结构，两端都想当 host 就谈不起来。

gnirehtet 的做法是在手机侧建一个 VPN，把全部流量经 adb 隧道转给 Mac 中转。

## 安装

### 1. 先装两个依赖

```bash
brew install gnirehtet
brew install --cask android-platform-tools
```

`gnirehtet` 是反向共享的实现，`adb` 用于和手机通信。缺哪个 App 都会弹窗提示，
并能一键复制安装命令。

### 2. 装 App

**方式一：Homebrew**（推荐，依赖会自动装好）

```bash
brew tap daily-units/mactoandroid
brew trust daily-units/mactoandroid
brew install --cask --no-quarantine mactoandroid
```

`brew trust` 这一步不能省——新版 Homebrew 拒绝加载未信任第三方 tap 里的 cask，
不先信任连 `brew info --cask mactoandroid` 都会报
`Refusing to load cask ... from untrusted tap`。这是 Homebrew 的安全策略，不是本项目特有的。
`--no-quarantine` 同样不能省，原因见下。

**方式二：下载现成的 .app**

到 [Releases](https://github.com/daily-units/MacToAndroid/releases) 下载 `MacToAndroid-<版本>.zip`，
解压后拖进「应用程序」。**第一次打开会被系统拦住**，提示「无法打开，因为无法验证开发者」
——这个 App 只做了 ad-hoc 签名、没有经过 Apple 公证（公证需要每年 99 美元的开发者账号）。

最省事的做法是先去掉隔离标记，再正常双击：

```bash
xattr -dr com.apple.quarantine "/Applications/MacToAndroid.app"
```

不想开终端的话：双击一次让它被拦下，然后到 **系统设置 → 隐私与安全性**，
在下方找到刚才那条拦截提示，点「仍要打开」，只需做一次。

> **旧教程里的「右键 → 打开」在新系统上已经不管用了。** macOS 15 (Sequoia) 起
> Apple 移除了 Control-click 绕过 Gatekeeper 的路径，未公证的应用只能走上面两条。
> 本地编译出来的 App 不带隔离标记，这一步整个可以跳过。

**方式三：从源码构建**

```bash
./build.sh
```

需要 `swiftc`（Xcode 或 Command Line Tools，`xcode-select --install`）。
本地编译出来的 App 不带隔离标记，上面那一步整个可以跳过。

`build.sh` 出的是 **arm64 + x86_64 通用二进制**（两个架构分别编再 `lipo` 合并）。
只编本机架构的话，Intel Mac 拿到会直接报「应用程序不支持此 Mac」，
而这种错误往往要等别人下载之后才会被发现。

### 3. 首次运行会自己装好

打开后菜单栏出现图标。App 会自动把 `mta-ctl.sh`、`watcher.sh` 铺到
`~/Library/Application Support/MacToAndroid/`，并注册两个登录项
（后台守护进程 + 菜单栏应用自启）。**不需要跑任何安装脚本。**

### 4. 手机端准备

开发者选项里要开三个开关（小米 / HyperOS 都要求已登录小米账号）：

- **USB 调试**
- **USB 安装** — 否则装不上手机端客户端，报 `INSTALL_FAILED_USER_RESTRICTED`
- **USB 调试（安全设置）** — 否则 Mac 拉不起手机端客户端，报 `WRITE_SECURE_SETTINGS`。
  系统更新后可能被重置

插上数据线，手机上会弹「允许 USB 调试」，勾选「一律允许」。

### 5. 开始用

点菜单栏图标 → **开启自动模式**。第一次会问「要把网络共享给这台设备吗」，选「共享」。
手机端客户端会自动安装（没有桌面图标，由 App 通过 adb 拉起）。

之后插上线就自动连接，不用点任何东西；开机登录也会自动恢复。

开启自动模式时如果还没插设备，会弹一句「当前没有已连接的设备，插上开启了 USB 调试的
Android 设备后会自动处理」。**它只是说明，不阻塞等待**——守护进程常驻，插上线自然会接手，
所以这里不需要停在原地等设备出现。

### 卸载

> **把 `.app` 拖进废纸篓是不够的。** 这个 App 装了两个 LaunchAgent，而 macOS 对
> LaunchAgent 没有任何自动清理机制（「登录项与扩展」只能停用、删不掉 plist）。
> 删掉 `.app` 之后守护进程照样开机自启、插线照样共享——留下的不是「配置残留」，
> 是「功能残留」。所以请用下面任一种方式。

**方式一：菜单里点** —— 菜单栏图标 → **卸载 MacToAndroid…**。弹窗会列清要删的东西，
勾选框可以顺带清掉设备列表、日志和手机端客户端。App 会立刻退出，过程记录在
`~/Library/Logs/MacToAndroid-uninstall.log`（这个文件刻意放在日志目录之外，
免得被自己删掉）。

**方式二：Homebrew**（如果是用 cask 装的）

```bash
brew uninstall --zap mactoandroid
```

`--zap` 会连配置和日志一起清。cask 里显式写了 `launchctl` 与两个 plist 的清理——
不写的话 brew 也只是删掉 `.app`，守护进程会留下。

**方式三：命令行**。脚本会随 App 一起铺到运行目录，所以**不需要源码**：

```bash
"$HOME/Library/Application Support/MacToAndroid/uninstall.sh" --purge
```

不加 `--purge` 只清 Mac 侧（保留设备允许/拒绝列表和日志）。有源码时 `./uninstall.sh`
等价。它会先趁 adb 还通把手机端 VPN 掐掉，再 bootout 两个 LaunchAgent、
只杀确认属于自己的 relay（扫 `31416..31425` 整段，因为端口会自动切换），最后删文件并自检残留。

**连脚本都没了**的话，手动清理这些位置——注意 `$TMPDIR` 那个状态目录和 relay 兜底，
这两项容易漏：

```bash
osascript -e 'tell application id "com.local.mactoandroid.app" to quit' 2>/dev/null; pkill -f '/MacToAndroid.app/Contents/MacOS/' 2>/dev/null; launchctl bootout "gui/$UID/com.local.mactoandroid.menubar" 2>/dev/null; launchctl bootout "gui/$UID/com.local.mactoandroid" 2>/dev/null; rm -f ~/Library/LaunchAgents/com.local.mactoandroid*.plist; for p in $(lsof -nP -iTCP:31416-31425 -sTCP:LISTEN -t 2>/dev/null); do case "$(ps -o comm= -p "$p")" in *gnirehtet*) kill -9 "$p";; esac; done; rm -rf ~/Library/"Application Support"/MacToAndroid ~/.config/mactoandroid ~/Library/Logs/MacToAndroid "${TMPDIR:-/tmp}"/MacToAndroid /Applications/MacToAndroid.app
```

卸载脚本还会带走 App 派生出来的 `mta-ctl` 进程（比如正在跑的 `install-client`，最长 180 秒）。
不这么做的话那个孤儿之后任何一步都会 `mkdir -p` 状态目录，于是刚删掉的目录又回来了；
残留检查现在也会把状态目录列进去，被重建时如实报出来（重启即清）。

手机端客户端任何方式都不会自动卸（它装在手机上），需要时：

```bash
adb uninstall com.genymobile.gnirehtet
```

## 用法

装好后菜单栏出现一个图标，共享中时点亮、自动模式关闭时变暗。点开就是全部功能：

```
    ┌──────────────────────────────────────┐
    │ 自动模式：已开启                      │
    │ 关闭自动模式                          │
    │ ──────────────────────────────────── │
    │ relay        运行中                   │
    │ 共享中       1 台                     │
    │ DNS          192.168.100.1,8.8.8.8   │
    │ ──────────────────────────────────── │
    │ 设备（展开有更多操作）                 │
    │  ✓ Redmi K70          共享中          │
    │    Pixel 7            未共享          │
    │    Galaxy S23         已拒绝          │
    │ ──────────────────────────────────── │
    │ 环境自检…                             │
    │ 打开日志文件夹                        │
    │ 退出 MacToAndroid                     │
    └──────────────────────────────────────┘
```

每台设备只有两个操作，且**随状态变化**——一台设备不可能同时「已允许」和「已拒绝」，
所以两个按钮永远不会语义重叠：

| 设备状态 | 按钮 1 | 按钮 2 |
|---|---|---|
| 共享中 / 已允许 | 停止共享 | 不再询问 |
| 未共享 | 开始共享 | 不再询问 |
| 已拒绝 | 开始共享 | **清除记录** |

- **停止共享** — 移出允许列表，回到「未共享」。下次连接会重新询问。
- **不再询问** — 加入拒绝列表，永不共享也永不弹窗。随时可撤销。
- **清除记录** — 只对已拒绝的设备出现。从「已拒绝」回到「未共享」而不直接允许，
  这是它唯一不可替代的用途。

早期版本三个按钮并列（停止共享 / 拒绝 / 忘记），而**「忘记」对已允许的设备与
「停止共享」完全等价**——只是多清了一个本来不存在的 deny 记录，用户看不出区别。
「拒绝」也改名为「不再询问」，因为那才是它真正的作用。


菜单里「退出」只关掉图标，**共享和守护进程都不受影响**——要彻底停止请先
「关闭自动模式」。

发现陌生设备时会弹一个原生对话框询问，三个选项：共享 / 以后再说 / 拒绝并不再询问。

### 打开窗口

菜单里「打开窗口」展开一个原生窗口——设备多、要对照拒绝列表、要做拒绝/忘记时比菜单顺手：

```
┌────────────────────────────────────────────────────┐
│  自动模式：已开启                   [关闭自动模式]  │
│  ────────────────────────────────────────────────  │
│  relay 运行中 · 共享 1 台 · DNS 192.168.100.1,...  │
│  ────────────────────────────────────────────────  │
│  设备                                               │
│  ┌──────────────────────────────────────────────┐  │
│  │ Redmi K70                                    │  │
│  │ 9f8e7d6c  共享中   [停止共享] [不再询问]      │  │
│  ├──────────────────────────────────────────────┤  │
│  │ Pixel 7                                      │  │
│  │ 1A2B3C4D  未共享   [开始共享] [不再询问]      │  │
│  └──────────────────────────────────────────────┘  │
│  [刷新] [环境自检…] [打开日志文件夹]                │
└────────────────────────────────────────────────────┘
```

窗口开着时每 5 秒自动刷新，插拔设备不用手动点刷新。关掉只是隐藏，下次打开复用同一个窗口。

调试时可以跳过点菜单直接开窗口：

```bash
MTA_OPEN_WINDOW=1 /Applications/MacToAndroid.app/Contents/MacOS/MacToAndroid
```

### 关于图标与 App

「应用程序」里只有 `MacToAndroid.app` 一个图标。它是 LSUIElement 应用——
只出现在菜单栏，不占 Dock、不进 ⌘Tab。

## 设备策略

**只有 USB 连接的真机参与策略。** 模拟器（`emulator-5554`）和无线调试连上来的设备
（`192.168.1.50:5555`）自身就有网络，反向共享既无意义也做不到，所以直接忽略——
不询问、不出现在设备管理列表里，只在 `mta-ctl ignored` 和日志里能查到。

| 情形 | 自动触发时的行为 |
|---|---|
| 已允许 | 静默开始共享 |
| 已拒绝 | 静默忽略，不再询问 |
| 陌生设备 | 唤起 App 询问「要共享给它吗」。选共享则加入允许；选拒绝则加入拒绝 |
| 条件不满足（没装客户端、版本不一致等） | **完全静默**，只写日志 |

「陌生设备要询问」是唯一会主动打扰用户的自动行为——插线充电不该被弹窗骚扰，
但把网络共享给一台没见过的设备需要用户确认。

**询问的粒度是「每次连接一次」，不是「每次开机一次」。** 设备真正断开
（离开超过 8 秒，避免 USB 抖动误判）后询问记录会被清掉，所以重新插上会再问一次。
重新插上正是用户表达「我想重新决定」的动作，比等到下次开机更符合直觉；
选了「以后再说」之后也是拔插一次就能再被问。

**「停止共享」和「清除记录」都不会立刻重新询问。** 两者都把设备变回「未共享」，
同时标记为「本次连接已问过」。否则紧跟的对账会发现它成了陌生设备并立刻弹窗——
用户刚点「停止共享」就被追问「要不要共享」，像是应用在跟你对着干。
想重新被询问，拔下再插上即可。

## 架构

```
MacToAndroid.app          只做界面：状态面板、设备管理、询问、引导
        │
        ├──────────────┐   两者调用同一份策略实现，避免逻辑漂移
        ▼              ▼
watcher.sh        mta-ctl.sh          核心控制器
(LaunchAgent)     ├─ gnirehtet relay        一个常驻 relay，127.0.0.1:31416
阻塞在            └─ gnirehtet start/stop   每台设备独立启停 client
adb track-devices              │
                               ▼
                        手机端 VpnService   把全部流量转给 Mac
```

`gnirehtet run` 只能服务一台设备，所以这里不用它，而是把 `relay` 和 `start/stop`
拆开用——一个 relay 能同时服务多个 client，这是支持多设备的前提。

`mta-ctl.sh` 是一个可以直接在终端用的 CLI，调试时很方便：

```bash
CTL="$HOME/Library/Application Support/MacToAndroid/mta-ctl.sh"
"$CTL" summary            # auto= relay= shared= dns= ignored=
"$CTL" status             # serial<TAB>标签<TAB>状态（只含 USB 真机）
"$CTL" ignored            # 被忽略的设备及原因
"$CTL" sync-dns           # 立即按本机当前 DNS 重新下发
"$CTL" allow <serial>     # 允许并立即共享
"$CTL" unshare <serial>   # 停止共享，下次连接会重新询问
"$CTL" deny <serial>      # 不再询问（永不共享、永不弹窗）
"$CTL" forget <serial>    # 从允许/拒绝列表彻底移除，恢复为陌生设备
"$CTL" auto on|off
"$CTL" why <serial>       # 这台设备为什么没在共享（已在共享则输出空）
"$CTL" install-client <serial>    # 在手机上安装客户端
"$CTL" push-client <serial>       # 把 APK 推到手机下载目录（USB 安装被禁时的退路）
"$CTL" reconcile          # 让实际状态收敛到策略
```

## 配置

`~/.config/mactoandroid/`

| 路径 | 作用 |
|---|---|
| `enabled` | 存在则启用自动模式 |
| `allow/<serial>` | 允许共享。文件内容是型号名，供 UI 在设备离线时仍能显示可读名称 |
| `deny/<serial>` | 拒绝，不再询问 |
| `pending-ask` | 待询问的陌生设备队列，守护进程写、App 读 |
| `only-when-offline` | **需手动创建**。存在则仅在手机自身没有网络时才接管 |
| `allow-outside-applications` | 用户对「不在应用程序目录里运行」选过「仍在此处运行」的那个路径 |

只想充电时不被接管：

```bash
touch ~/.config/mactoandroid/only-when-offline
```

判断依据是 `dumpsys connectivity` 里有没有非 VPN 的 `CONNECTED` 网络。

## 实现要点

**为什么不用轮询** — `adb track-devices` 是流式的：设备状态变化时推一条，中间阻塞。
守护进程挂在 `read` 上不消耗时间片。它的输出形如 `00101a2b3c4d<TAB>device`，
**前 4 位是十六进制长度前缀而非序列号的一部分**，所以代码不解析内容，
只把它当作「状态变了」的信号，再让 `mta-ctl` 用 `adb devices` 取权威列表。

**`read -t` 的超时返回码在 macOS 上是 1，不是 >128。** `#!/bin/bash` 在 macOS 上永远指向
系统自带的 **bash 3.2.57**（Homebrew 的 bash 5 在 `/opt/homebrew/bin/bash`，shebang 不会走那儿）。
bash 3.2 的 `read -t` 超时返回 **1**；「超时返回 >128」是 bash 4.0 之后才有的约定。

守护进程原来用 `rc -gt 128` 判心跳、`else` 判 EOF，于是**心跳分支永不成立**，每次心跳
都被当成「adb server 挂了」。更糟的是 `read` 当时跑在管道右侧的子 shell 里：子 shell 一
`break` 就退出，父进程接着 `wait` 左边的 `adb track-devices`——而它空闲时不会退出
（只有下次写管道拿到 EPIPE 才死），父进程就卡在 `wait` 里，连「track-devices 中断」
那行日志都写不出来。

净效果是**守护进程在最后一次设备事件之后约 20 秒彻底静默，`health` / `heal` 一次都没跑过**：
relay 存活检查、FD 耗尽自愈、DNS 重新下发、无事件时的隧道修复、宽限期到期后的再判定、
首次对账失败的重试，全部形同不存在（隧道修复实际是 App 的轮询在兜，App 一退出就没了）。

而它**看起来完全正常**：插线时 adb 写管道拿到 EPIPE 而死，父进程的 `wait` 才返回，
重连后首帧就是权威列表，照样对上一次账——只是每个事件多 3 秒延迟。所以这个故障能长期
潜伏。查证方式：守护进程几十分钟的 CPU 累计时间（`ps -o time`）只有 `0:00.02`，
`watcher.log` 长时间一行不写，而 `relay.log` 涨过 200 KB 却从没被截断
（`trim_log` 只在 `health` 里调用，日志超限还在长就等于 `health` 没跑）。

现在不再依赖返回码：`adb track-devices` 写进一个 FIFO，读端在**主 shell** 里（没有子 shell），
超时与 EOF 用 `kill -0 $adb_pid` 区分，和 bash 版本无关。FIFO 用 `<>` 打开——只读打开会
阻塞到有写端为止，adb 万一启动就失败（运行期间被卸载）又是一次永久卡死。

**空设备列表那一帧没有换行。** `adb track-devices` 在列表为空时只发 4 个字节 `0000`
（十六进制长度前缀 0，后面什么都没有），所以**拔掉最后一台设备**时凑不出完整一行：
bash 4+ 会把这半行留在变量里，bash 3.2 干脆丢掉。于是「拔掉最后一台」根本不产生事件，
宽限标记没人打，也就没人重新评估——界面一直显示「共享中」、relay 一直挂着。

修法是在 adb 和读循环之间插一个**读帧器**（`/usr/bin/perl`，8 行）：按「4 位十六进制长度
+ 该长度的负载」切帧，每帧输出一行，空列表帧就成了正常事件。它**只输出长度、不输出负载**，
所以下游照旧不解析内容，只当「状态变了」的信号；长度离谱（>64KB）时直接退出让上层重连，
不在错位的流上一直读下去。perl 是 Apple 捆绑的运行时、已被标记 deprecated，所以不在时
自动退回直接读——`MTA_NO_FRAMER=1` 可以强制走回退路径，因为**没人跑的分支一定会腐烂**。
回退模式下「拔掉最后一台」仍然看不到，靠两道兜底：正在共享时心跳从 20 秒压到 5 秒，
以及 `health` 里那条「共享列表里的设备是否还在线」的检查（后者同时兜住
「设备事件正好撞上抢不到锁而被丢掉」）。

实测（假 adb 喂 4 帧、最后一帧是空列表）：读帧模式读到 4 个事件、含空列表帧那个；
回退模式只读到 3 个半——最后那 4 字节读不成行。

**读帧器有四道保险，因为它是新增的故障点：**

- *帧尾校验*：非空负载必然以换行结尾（每台设备一行 `serial<TAB>state\n`）。不是的话说明
  长度读错、流已经错位，立刻退出让上层重连——**吵，但不静默**。
- *启动自检*：每次启动喂一个已知向量（一帧 `ab\n` + 一帧空列表，期望输出 `3` 和 `0`），
  对不上就退回直接读并记一条日志。读帧器坏掉（perl 被换掉、程序在未来版本上行为变了）
  应该在启动时就降级，而不是带着一个坏读帧器跑——那会变成「事件全都收不到」，
  正是最难查的那种故障。实测：把读帧器换成一个输出垃圾的脚本，守护进程如实降级成 direct。
- *连续短命就整会话降级*：启动自检拦得住「一上来就坏」，拦不住「自检过了、遇到真实数据
  才退」——比如 adb 换了帧格式，帧尾校验每次都触发。那种情况的表现是每 3~60 秒重连一次、
  永远好不了。所以读端连续 3 次存活不足 5 秒就把读帧器关掉，本会话改用直接读：
  会丢「拔掉最后一台」那个事件（有心跳兜），但不会陷在重连循环里。
  实测：让假 adb 发一个负载不以换行结尾的坏帧，第 3 次之后如实降级、模式落盘为 direct。
- *模式落盘*：`$TMPDIR/…/framer` 记着当前走的哪条路，`mta-ctl doctor` 里能直接看到。

**写端退出要补一行哨兵。** 读端是用 `<>` 打开的（自己也算写端），所以 adb 或读帧器死掉时
**永远收不到 EOF**，只能等下一次读超时才靠 `kill -0` 发现——实测要 12 秒。
现在读帧器外面套一层 `( 读帧器; printf 哨兵 )`，它一退出就往 FIFO 补一行
`__mta_writers_gone__`，读循环认出来立刻重连。实测：杀读帧器 → 同一秒就记下「中断」；
杀 adb → 读帧器读到 EOF 自己退 → 同样即时。`adb kill-server` 的恢复也因此从
「最长一个心跳 + 3 秒」变成「约 3 秒」。

顺序有讲究：停止时**先杀 adb**，让读帧器的 stdin 自然 EOF、外层 subshell 随之结束；
反过来直接杀那个 subshell 会把 perl 留成孤儿（它还持着两个 FIFO）。

**缓存为空时不能输出空行。** `devices_long` 的结果在进程内缓存，早期版本用
`printf '%s\n' "$cache"` 输出，缓存为空时会补出一个换行——那一行被 awk 当成一条记录，
于是统计出一台序列号为空的「被忽略设备」，日志里是 `已忽略: = `。这类 bug 不会让功能
失效，只会让统计和界面出现看不懂的东西。

**只认 USB 真机** — `adb devices -l` 的一行形如
`1a2b3c4d  device  usb:1-1 product:example model:EXAMPLE_X1 ...`，
**只有 USB 连接的物理设备才带 `usb:` 字段**。模拟器和无线调试设备都没有，
所以一次 `adb devices -l` 就能把两类一起排除，不必对每台设备额外调 `adb shell`。
另有一道兜底：`preflight` 里查 `ro.kernel.qemu` 与 `ro.hardware`
（goldfish / ranchu / vbox86 / cutf 都是模拟器），防止某种「USB 连上来的虚拟设备」
骗过 `usb:` 字段。

**DNS** — gnirehtet 没有「跟随宿主 DNS」的选项，不给 `-d` 就写死用 `8.8.8.8`，
境内会慢且拿不到就近 CDN 节点。所以每次下发前都用 `scutil --dns` 现读一次本机 DNS，
以 `-d 本地DNS,8.8.8.8` 传入，不需要任何手动配置。

**必须遍历所有 `nameserver` 条目，不能只取 `nameserver[0]`。** 路由器广告 IPv6 DNS 时
它会占据 `[0]`：

```
nameserver[0] : fe80::1%en0      ← gnirehtet 的 -d 不支持 IPv6
nameserver[1] : 192.168.100.1    ← 真正能用的在这里
```

只读 `[0]` 会判定为「没有可用 DNS」而回落到写死的 8.8.8.8——恰好绕开了这个功能本身
要解决的问题，而且不报错、无从察觉。踩过一次。

切换 Wi-Fi 或接入 VPN 后本机 DNS 会变，手机侧却还用着旧的。心跳每 20 秒比对一次
（`scutil` 很快），同一个新值连续两次心跳都出现才下发（网络切换时 DNS 会短暂抖动，
立刻重启会让隧道反复断开），确认后对在共享的设备 `gnirehtet restart -d 新DNS`。
可用 `adb shell dumpsys connectivity | grep DnsAddresses` 验证。

**必须抬高 relay 的文件描述符上限。** `launchctl limit maxfiles` 给 launchd 会话的
软上限只有 **256**（交互 shell 里通常是 1048576，所以在终端手动跑 relay 察觉不到），
而 relay 每个连接占一个套接字。撑爆之后：

```
ERROR Router: Cannot create route, dropping packet: Too many open files (os error 24)
```

**每个新包都被丢弃，而且不会自行恢复**——gnirehtet 的 UDP 连接要等超时才释放，
同时应用的重试风暴持续制造新连接。实测撑爆时的现场：60 秒内 UDP Open 321 / Close 0、
TCP Open 269 / Close 3，DNS 每秒重试数次。

而这个故障**完全静默**：界面绿灯、隧道正常、手机 VPN 图标亮着，就是一个包都过不去，
唯一线索是那行 ERROR 埋在几千条流量记录中间。

修法是启动 relay 前抬高软上限（硬上限是 `unlimited`，无需特权），并在 LaunchAgent
的 plist 里加 `SoftResourceLimits`：

```bash
( ulimit -n 8192; exec nohup gnirehtet relay -p "$PORT" >> "$RELAY_LOG" 2>&1 ) &
```

用子 shell 加 `exec` 而不是直接 `ulimit`：前者不影响调用者，`exec` 又保证 `$!`
仍是 relay 自己的 pid。另外注意 `ulimit -n N` 在 bash 里会**同时**降低软硬上限，
测试这个机制时必须用 `ulimit -S -n` 才能复现 launchd 的 256/unlimited 状态。

`summary` 里有 `fd_exhausted=`（只看日志尾部 200 行，成本可忽略），
心跳发现后会自动重启 relay，菜单和窗口也会告警并提供手动入口。

**日志轮转必须原地截断，不能 `mv` 覆盖。** relay 是以 `>> relay.log` 启动的常驻进程，
它的 fd 指向 inode 而不是路径。`tail -c … > tmp && mv tmp relay.log` 之后，relay 会继续往
被 unlink 的旧 inode 里写：relay.log 从此冻结在轮转那一刻，而 `fd_exhausted()` 读的是新文件
——上面那个「界面绿灯却一个包都过不去」的静默故障，**探测手段本身被静默地掐掉了**。
改成 `cat tmp > relay.log`（O_TRUNC，inode 不变）即可，写入者的 fd 仍然有效。

relay 每次启动还会往日志里打一行 `=== relay start … ===`，`fd_exhausted()` 只看最后一个
标记之后的内容——否则上一轮遗留的 ERROR 行会让心跳白重启一次 relay，把所有共享打断。

**隧道存活要单独检查，不能只看 relay 进程。** USB 重新枚举会摧毁 `adb reverse` 隧道，
而手机端的 VpnService 不会跟着退出。此时 `gnirehtet start` 判定「客户端已在运行」
什么都不做，状态显示「共享中」但流量进了 `tun0` 就死掉——**手机上 VPN 图标亮着却没有网络**。

这个状态最容易误导人：界面绿灯、手机有 VPN，只能怀疑手机设置。所以
`summary` 里有 `tunnel=ok/broken`，判据是 `adb -s <serial> reverse --list` 里
有没有 `tcp:<PORT>`。断了就用 `gnirehtet tunnel <serial> -p <PORT>` 重建——
代价远小于整个重启，而且不打断手机端的 VPN。检查点在两处：设备事件（即时）和
20 秒心跳（覆盖「没有事件但隧道断了」）。菜单和窗口都有「修复隧道」手动入口。

**值得记下的因果关系：** 这个缺口是修上一条 bug 时引入的。原先 `client_start`
无条件 `stop`+`start`，副作用是顺带重建了隧道；为消除隧道抖动去掉 `stop` 之后，
那个「误打误撞的修复机制」也没了。所以隧道重建必须显式做。

**已在共享的设备走快路径，绝不先 stop。** `client_start` 里有一句
`gnirehtet stop` 用来清理拔插后残留在手机上的僵尸 VPN——但它只在**首次启动**时才需要。
早期版本无条件执行，于是每个设备事件都会把隧道拆掉重建一次（relay 日志里成对出现
`Client #N disconnected` / `Client #N+1 connected`）。USB 接触不良时设备事件每分钟好几次，
手机就会不停瞬断，表现是「莫名其妙自动断线」，而日志里看不出任何错误。

实测：修复前 3 次对账产生 6 条 Client 事件（3 次完整重建）；修复后 5 次对账产生 **0 条**，
耗时也从约 1400ms 降到 702ms（跳过了 preflight 的约 150ms adb 往返）。

**设备短暂消失有 8 秒宽限期。** USB 接触不良会造成 1~3 秒闪断。一消失就拆隧道的话，
每次抖动都要用 `gnirehtet stop`+`start` 重建一遍（约 2 秒），反而把抖动放大成持续空转。
所以「仍在允许列表却不在线」会先打一个时间戳标记，超过宽限期才真正停止；
而「用户主动取消共享」立即生效——两者语义不同，不能混。宽限期内也不能停 relay，
否则等于白等。

**自愈** — 心跳 20 秒只做一次 `lsof` 检查 relay 是否存活（极廉价）；每 300 秒
（按时间算，不按心跳次数——心跳间隔是可变的，按次数算会让自愈频率跟着漂）对每台在共享的设备重新调一次 `gnirehtet start`。因为 `start` 是幂等的
（「若 client 已启动则什么都不做」），所以不需要先检测 client 死了没，直接重复调用
就能把被系统清理掉的 client 拉回来。

**状态判断用端口而非 pgrep** — `pgrep -f gnirehtet` 会匹配到 App 自身的进程路径，
导致永远判定为「正在运行」。

**运行时脚本不能放 `~/Documents`** — 该目录受 TCC 保护，LaunchAgent 读不到，
会以 `Operation not permitted` 反复重启。所以 `build.sh` 把脚本复制到
`~/Library/Application Support/MacToAndroid/`，plist 指向那份副本。

**图标** — 底图放成 `icon.png`（正方形 PNG，建议 1024 以上），`build.sh` 会自动处理。
这一环在 macOS 26 上有个坑，不报错、只是默默显示成别的图标：**带透明边距的图会被
垫上浅色底板。** macOS 26 的图标系统把「带透明边距的旧格式
图标」缩小放进一个浅色圆角底板里（Chrome 的圆形 logo 就是这个效果），而 Mail、Journal
那种满幅观感要求图**满幅不透明**、由系统自己切圆角。所以 `build.sh` 对带 alpha 的底图
先调 `make-icon.py --full-bleed`：裁掉透明边距，把半透明处按徽章底色合成，输出满幅不
透明图，再交给 `sips` 切十档尺寸。填充色取自徽章内部往里 24px 处——不能取边缘，
那里通常是描边高光。

验证系统**实际**解析出的图标（不是文件里存的那张）：

```bash
swiftc -O -o /tmp/geticon geticon.swift && /tmp/geticon /Applications/MacToAndroid.app /tmp/out.png
```

`geticon.swift` 调 `NSWorkspace.icon(forFile:)`，和访达/Dock 走同一条链路。
`qlmanage -t` 作用在 `.app` 上会挂死，别用它。

改完图标若仍显示旧图，是缓存：

```bash
CACHE="$(getconf DARWIN_USER_CACHE_DIR)"
killall -KILL iconservicesagent
rm -rf "$CACHE/com.apple.dock.iconcache" "$CACHE/com.apple.iconservices" "$CACHE/com.apple.iconservicesagent"
killall Dock; killall Finder
```

**`make-icon.py` 为什么是纯 Python 手写的** — 这台机器上没有任何图形库
（无 PIL / cairosvg / ImageMagick / rsvg-convert），而 `qlmanage` 渲染 SVG 时会把透明
区域**合成到白底**，做不出 alpha。所以 PNG 的解码、遮罩、编码全部自己实现。
它只做一件事——把带透明边距的图裁剪并按徽章底色合成成满幅不透明图。

**`$变量` 后面不能紧跟全角字符。** bash 3.2 判断变量名用的是 locale 相关的 `isalnum()`，
**UTF-8 locale 下多字节字符的首字节会被算进标识符**。于是 `"$APP（未注册）"` 被解析成
变量 `APP\xef`，配上 `set -u` 就直接退出：

```
./build.sh: line 202: APP?: unbound variable
```

而 `LANG` 未设置或 `C` 时完全正常——**launchd 就是这种环境**，所以守护进程和 App
调这些脚本从来不出事；只有用户在自己的终端里（`LANG=en_US.UTF-8` / `zh_CN.UTF-8`）
手动跑 `./build.sh`、`./release.sh` 时才会现形。实测同一段脚本：`LANG=C` 正常，
`LANG=en_US.UTF-8` 报 unbound variable。

写法上一律用 `${VAR}（…`。项目里踩到 8 处（含端口冲突提示里的两处老代码）。
现在 `release.sh` 的出包前检查里有一条静态扫描——找 `$名字` 紧跟 0x80–0xFF 字节的位置
（跳过注释行），命中就拒绝出包。

教训不止于这一个 bug：**在 `LANG` 未设置的环境里测，测不出任何 locale 相关的问题。**
改完脚本至少在 UTF-8 locale 下把 `build.sh` / `release.sh` / `mta-ctl` 的主要子命令
各跑一遍。

**bash 3.2 + `set -u` 下，空数组的 `"${arr[@]}"` 会直接报 unbound variable**
（`${#arr[@]}` 是安全的）：

```
$ bash -c 'set -u; A=(); echo "${A[@]}"'   →  A[@]: unbound variable
```

`build.sh` 里拼通用二进制那段用了数组，目前靠 `[ ${#SLICES[@]} -gt 0 ]` 短路挡住了，
往那段加代码时要留意。

**zsh 不做分词** — 项目里的脚本都是 `#!/bin/bash`，因为 `set -- $spec` 这类写法
在 zsh 下不会按空格拆分（zsh 默认不对未加引号的参数展开做分词），会导致
`sips` 拿到错误参数、iconset 为空、`iconutil` 报 `Failed to generate ICNS`。
在终端里手动跑这些循环时要用 `bash -c`。

## 日志

日志在 `~/Library/Logs/MacToAndroid/`（不放 `/tmp`——那是所有用户共享且可写的）：

| 文件 | 内容 |
|---|---|
| `watcher.log` | 设备事件、心跳、重连 |
| `ctl.log` | 策略决策：谁开始/停止共享、跳过原因、端口冲突 |
| `relay.log` | relay 明细 |
| `watcher.err` | 守护进程 stderr |

超过 200 KB 自动截断保留尾部——**包括 plist 里 `StandardErrorPath` 指向的那两个 `.err`**。
它们平时是 0 字节，但只要出现「每 20 秒报一次错」这类循环就会无限长，而原来没人管它们。
注意它们由 launchd 持有 fd，所以同样必须原地截断（见上面那条轮转的坑）。

易变状态在 `$TMPDIR/MacToAndroid/`（每用户独立、开机清空）：`active`（正在共享的设备）、
`asked`（本次开机已问过的设备）、`dns`、`lock`。

排查第一步：

```bash
"$HOME/Library/Application Support/MacToAndroid/mta-ctl.sh" doctor
```

输出依赖位置、APK 路径、状态目录、App 路径、端口占用情况。

## 安全与可靠性

这些是按「别人拿去用也不会被坑」的标准做的处理，不是可选项：

**不会误杀进程，端口被占时自动换。** 31416 是 gnirehtet 的默认端口，但它不是注册端口，
任何程序都可能占用。所以在 `kill` 之前会核对进程名**和所有者**（同一台 Mac 上别的用户
也可能在跑 gnirehtet，那个 relay 不是我们的），绝不去结束占用端口的进程。

被占时会在 `31416..31425` 里自动挑一个空闲端口，并把选中的值持久化到
`$TMPDIR/MacToAndroid/port`——relay 与各设备的 client 由不同次调用启动，
必须取到同一个端口，所以不能只存在内存里。实测：用另一个进程占住 31416 后开启自动模式，
自动切到 31417、`adb reverse` 隧道随之指向 `tcp:31417`、手机正常连上，
占位进程未受影响。十个端口全被占才会放弃并提示。

界面在端口不是默认值时会显示「（端口 31417）」，因为这说明发生过切换，值得让用户知道。

**端口被占不阻断任何操作。** 菜单和窗口只多一个禁用的说明项
`⚠ 端口 31416 被其他程序占用`，共享照常在换过去的那个端口上跑。会真正拦下来的只有
「十个端口全被占」这一种，那时才是真的没法工作。

**版本号只比数字部分。** Mac 侧的版本是从 Homebrew 的 Cellar 目录名推断的（`2.5.1`），
修订版会写成 `2.5.1_1`；手机侧取的是 APK 的 `versionName`（`2.5.1`）。直接比字符串会
永久判定「版本不一致」，而重装并不能让两者相等——设备永远卡在待启动，引导里重装四轮也
修不好。现在两边都先规整成开头的「数字和点」再比。`adb install` 也补上了 `-d`：
手机上的版本比 Mac 侧新时（用户从别处装过），不带 `-d` 会
`INSTALL_FAILED_VERSION_DOWNGRADE`，然后同样卡死在「版本不一致」。

**记住的机型名要能升级。** 离线预授权时 `model_of` 拿不到型号，写进 `allow/<serial>` 的
是序列号本身。早期版本「文件非空就跳过」，于是设备真的插上来之后名字也不会更新，
列表里永远显示一串序列号。现在内容等于序列号时会重取一次，共享成功时也顺手补一次
（文件里已经是机型名就不产生 adb 往返）。

**待询问队列要清理。** `pending-ask` 在 `~/.config` 下是**持久**的，而「本次连接已问过」
的记录在 `$TMPDIR` 里开机即失效。App 当时没在运行（退出过、`open` 失败、或者根本没装）
时排进去的条目会一直留着，下次启动 App 就弹窗询问一台早就拔掉的设备——点「共享」还会把
它写进允许列表。守护进程每次对账会清掉「不在线或已经有结论」的条目，App 那边再挡一道。

**DNS 候选要排掉手机到不了的地址。** 手机拿到的 DNS 是**它自己**要去连的地址（包经隧道
从 Mac 发出去），所以本机回环上的解析器（AdGuard / dnscrypt / Pi-hole 常绑 `127.x`）
下发过去只会让解析全部超时后才降级到 8.8.8.8。链路本地（`169.254/16`）和组播
（mDNS 的 `224.0.0.251` 会混在 `scutil --dns` 的输出里）同理，都要跳过。

**卸载要扫整个端口范围。** relay 未必在 31416 上（被占时会在 31416..31425 里自动换），
只看默认端口的话，「残留检查」会在 relay 还跑在 31417 上时报告「干净」。
`adb uninstall` 也必须逐台带 `-s`——插着两台时它会直接报 `more than one device`。

**序列号会被校验。** 它要拼进 `allow/<serial>` 这样的路径，不校验的话
`allow '../../../../tmp/x'` 就能写到预期之外的位置。只接受
`[A-Za-z0-9._:-]`、长度 ≤128、且不是 `.` / `..` / 含 `/`。

**包名要整行匹配。** `pm list packages | grep -q com.genymobile.gnirehtet` 会被
`com.genymobile.gnirehtet.foo` 这类包名命中。改成 `grep -qx "package:<pkg>"`，
注意 `adb shell` 的输出带 `\r`，`-x` 之前必须先 `tr -d`。序列号的匹配也统一加了
`-F --`：内容里的 `.` 不该被当成正则，开头的 `-` 更不该被当成选项（`valid_serial`
现在直接拒掉以 `-` 开头的序列号）。

**并发有锁。** App 和守护进程会同时调用控制器（用户点按钮的同一刻设备事件到达），
不加锁会重复启动 relay、`active` 文件互相覆盖。用 `mkdir` 的原子性实现，
并检测持有者是否已死，避免崩溃后永久死锁。实测 5 个并发对账后 `active` 无重复、relay 仅一个。

「`mkdir` 成功了但还没来得及写 pid」的窗口只有几毫秒，但如果持有者恰好在那个窗口里被杀，
锁里就是一个没有持有者的空 pid 文件——早期版本会干等满 30 秒再放弃，把这次操作白白丢掉。
现在连续 2 秒读不到 pid 就判定这个锁没人会释放，直接清掉。

**状态不放 `/tmp`，而且不能用 `${TMPDIR:-/tmp}` 兜底。** `/tmp` 所有用户可写，
固定文件名会被抢先创建成符号链接，所以状态要放每用户独立的临时目录，并 `chmod 700` + `umask 077`。

但写成 `${TMPDIR:-/tmp}` 会**恰好绕开这条决定**：SSH、cron 这类环境里 `TMPDIR` 可能是空的，
于是状态落回 `/tmp`——而且和守护进程用的是**两份不同的状态**：锁不共享，
从 SSH 里跑一次 `mta-ctl reconcile` 就可能起第二个 relay，两个 relay 抢同一个端口和设备。

现在三个脚本（`mta-ctl.sh` / `watcher.sh` / `uninstall.sh`）统一用
`getconf DARWIN_USER_TEMP_DIR`——它返回的就是 launchd 给的那个每用户目录，与环境变量无关；
拿不到才退回 `$TMPDIR`，**永远不退到 `/tmp`**（两个都拿不到就直接报错退出）。
实测：`env -u TMPDIR` 下解析出的目录与守护进程完全一致。

**不假设 Homebrew 前缀。** Intel Mac 的 Homebrew 在 `/usr/local`，MacPorts 在 `/opt/local`。
APK 路径从 `bin/gnirehtet` 包装脚本里的 `GNIREHTET_APK=` 读取，任何前缀都能找到。

**协议字段会消毒。** 型号名进入 `serial<TAB>标签<TAB>状态` 这个协议，
含制表符或换行会让解析方按 tab 切分时错位，所以统一 `tr -d` 并截断到 64 字符。

**守护进程有退避。** adb 长期不可用时按 3→6→12→…→60 秒指数退避，不刷日志；
恢复一次就重置。plist 里有 `ThrottleInterval`，启动失败不会被 `KeepAlive` 疯狂重启。

**NSScrollView 的文档视图必须翻转。** AppKit 的视图默认不翻转（原点在左下），
当文档视图比可视区域短时，`NSScrollView` 会把内容贴在**底部**——表现是设备列表
出现在「设备」标题下方一大段空白之后，看起来像是倒序排列。给文档视图套一层
`isFlipped = true` 的容器即可，布局才从上往下。

**AppKit 约束的激活时机。** `view.widthAnchor.constraint(equalTo: other.widthAnchor)`
必须在两个视图已有共同祖先之后才能激活，否则抛 `NSGenericException` 直接崩溃整个应用。
窗口里的设备行就踩过这个：约束写在 `deviceRow()` 里、而行还没入栈，一开窗口就崩。
现在改为入栈之后再加约束。纵向滚动的文档视图还要把宽度绑到
`scroll.contentView.widthAnchor`，否则内容不会撑满。

**每次「注册后台项目」都会给用户弹一条系统通知。** macOS 13 起，新增 LaunchAgent
会弹「App Background Activity —— "watcher.sh" can run in the background」。
`bootout` + `bootstrap` 等于「移除再添加」，所以每跑一次 `build.sh`、每次脚本更新后
App 自装重载，都会再弹一条——反复调试时能攒一屏。**这跟权限无关**：在「登录项与扩展」
里点过同意也不会让它消失，那个开关只决定它能不能跑（关掉它守护进程就不工作了）。

所以 plist 内容没变、服务还在时改用 `launchctl kickstart -k`：进程会换成新的
（脚本更新正需要这个），但注册关系不动，不触发通知。只有 plist 真的变了、或者服务
没加载时才走 bootout + bootstrap。`build.sh` 和 `Installer.swift` 两边都是这个逻辑，
输出里会写明走的哪条路。实测：连续两次 `build.sh` 都走 kickstart，守护进程 pid 换新、
`launchctl print` 里 `state = running` 从未中断。

首次安装那一条通知是躲不掉的，那是系统设计。真嫌吵可以在
「系统设置 → 通知」里关掉 *Background Items Added* 的通知——但别去关「登录项与扩展」
里的开关，那会直接停掉守护进程。

**`launchctl bootout` 是异步的，紧接着 `bootstrap` 会失败。** 服务还在退出时
bootstrap 报 `Bootstrap failed: 5: Input/output error`；`build.sh` 又是 `set -e`——
于是「App 装好了、守护进程却被卸载掉没装回来」，连后面的登录项注册也不会执行，
而脚本尾部那句「完成」根本不会打印，很容易被当成一次普通的安装。踩过一次。
`build.sh` 的 `write_agent` 和 `Installer.swift` 的 `syncAgent` 现在都会先轮询
`launchctl print` 等服务真的消失（最多 10 秒），bootstrap 失败还会隔一秒重试一次。

**列表项的身份是序列号，不是数组下标。** 窗口每 5 秒重建一次设备行，而 `tag = index`
是构建那一刻算出来的：拔掉一台之后列表变短、顺序变了，点击落到 action 时下标可能已经
指向另一台设备——「不再询问」打到别人身上很难解释。现在按钮是 `DeviceButton`（带
`serial` 字段）、菜单项用 `representedObject` 存序列号，动作里按序列号回查。

**同一个 bundle id 的第二份副本会自己退出。** 机器上很容易同时存在多份 `.app`——
构建产物、下载目录里的旧版、还没拖出来的 DMG 里那份。以前每份都能起来，
状态栏出现好几个图标；但真正的问题不在图标：`Installer` 写 `app-path` 和登录项时用的是
**自己的** bundle 路径，所以**后启动的那份会把「开机自启」和「守护进程唤起 App」都改指向
它自己**。那份副本一删（比如 `dist/` 被 `release.sh` 清掉）开机自启就静默失效，
而且改 plist 还会再触发一次系统的「后台项目已添加」通知。两个前端也会各自轮询、
各自弹一次「发现新设备」。

**后台从来不会重复。** 守护进程是按 label 注册的 LaunchAgent，launchd 保证同一域内
一个 label 只有一个进程；relay 也只有一个（按端口 + pid 文件识别，改状态的操作全过同一把锁）。
所以多副本的代价只落在前端。

现在启动时先查 `NSRunningApplication`：发现已有更早启动的同 id 实例就把它激活、自己退出。
先后要有确定的判据（比启动时间，pid 兜底），否则两份几乎同时启动会互相谦让、两个都退掉。
这个判断必须放在 `Installer.ensure()` **之前**——晚一步副本就已经把登录项改掉了。
实测：复制一份到别处直接运行，它自行退出，`app-path` 与登录项 plist 都没被动过、
状态栏仍只有一个图标。

仍然成立的一条是：**从哪份副本启动，登录项就指向那一份**。在「用户主动运行了那个副本」
的语义下这是对的，但也意味着从临时目录第一次启动会把自启指过去。所以
`release.sh` 打完包会删掉 `dist/` 里解开的 `.app`（只留 zip），
而「环境自检」里会显示当前界面所在的副本，并在它与 `app_path` 不一致时给出告警。

**不在「应用程序」里运行时会提示移过去。** 同一个根因：路径被记下来了。留在「下载」、
桌面或 `dist/` 里运行，位置一变或副本被删，开机自启就静默失效；从 DMG 里直接运行更糟，
卸载后路径直接消失。所以启动时先看自己在哪——`/Applications` 或 `~/Applications` 下
什么都不做，否则弹一次提示：「移动并重新打开」/「仍在此处运行」/「退出」。
这个判断同样要排在 `Installer.ensure()` **之前**。

三处必须单独处理：

- **「应用程序」里已有同名副本**：不覆盖，改成让用户直接打开那一份——否则会把另一份
  装好的 App 悄悄替换掉。
- **App Translocation**：带隔离标记从「下载」双击时，系统会把 App 挂到一个只读的随机
  路径上运行（路径里含 `/AppTranslocation/`）。这种状态下「移动」无从下手，真实位置不在
  那里，所以只提示先 `xattr -dr` 去掉隔离标记、或手动拖进「应用程序」。
- **重新打开必须延迟一秒**：新实例启动时若本进程还活着，它的单实例判断会发现有个更早
  启动的实例而自己退出——两边互相让位，谁都起不来。所以由一个脱离出去的 shell 等一秒
  再 `open`，本进程立刻退出。

「仍在此处运行」记的是**具体路径**（写进 `~/.config/mactoandroid/allow-outside-applications`），
换个位置还会再问。另外，已经有实例在跑时副本会在单实例判断那一步就退出、走不到这个提示,
所以它只在「第一份启动的就是临时位置那份」时出现。

实测：把副本复制到临时目录直接运行，提示如期弹出，而且在用户做出选择之前
`app-path` 与登录项 plist **都没有被改动**。

**装新版前会结束旧实例。** 残留的旧前端进程会占着同一个 bundle id，
LaunchServices 认为应用已在运行，`open` 就只发一个 reopen 事件，新装的二进制
根本不会被启动——表现是「装好了但菜单栏没图标」。这个坑踩过一次。

**「未授权」和「插着但 adb 读不到」必须分开报。** 前者是手机上没点「允许 USB 调试」，
后者是 USB 半死（`LIBUSB_ERROR_IO`）。早期版本拿 ioreg 里的 ADB 接口数减去
**状态为 `device` 的**设备数，于是未授权的设备也被算成「USB 半死」，界面常驻提示
「拔插它，或换一个 USB 口」——把用户支到完全错误的方向，真正要做的是解锁手机点允许。
现在减去的是「adb 能看见的所有实体设备」（带 `usb:` 的，加上状态不是 `device`、
又不是模拟器 / 无线调试的），未授权的那些走 `unauthorized=` 单独提示。

**依赖缺失会当场引导。** 直接下载 .app 的人不会先装 `gnirehtet` 和 `adb`。
缺了要说清楚怎么装，否则界面只显示「没有检测到设备」，看不出原因。
`summary` 里有 `deps=`，启动时缺依赖会弹窗给出 brew 命令并可一键复制，
菜单里也常驻提示。

**询问弹窗不能和引导弹窗叠在一起。** 两台陌生设备同时插上时，对第一台点「共享」后，
`Guide.share` 是异步的而代码紧接着就问下一台——于是用户在回答第二台的时候，
第一台的引导弹窗从上面冒出来。现在等这台的引导走完再问下一台，两处保险：
`refresh` 在个别路径上可能被调用多次，用一次性标记保证只继续一次；
万一某条路径忘了回调，5 分钟后兜底继续——否则 `askInProgress` 会永久为真，
之后**所有**陌生设备都不会再被询问。

**异步操作要有通知。** 菜单点击后会立刻关闭，而 `allow` 要等客户端真的连上（可能几秒），
完成时界面已经不在眼前了。图标和悬停提示虽然会更新，但那需要用户主动去看。
所以改状态的操作完成后会发一条通知（`Notify.swift` / `UNUserNotificationCenter`）。
前提仍然是 bundle 有 `CFBundleIdentifier`——没有的话通知会被系统静默丢弃。

**但界面反馈不能只靠通知。** 所有改状态的操作都以**可见的状态面板**收尾，面板本身承担
开关职责（自动模式开时显示「关闭自动模式」，关时显示「开启自动模式」），每次操作后
自动刷新；通知只是额外提示，不是唯一反馈途径。首次发通知时系统会请求权限，允许一下即可。

**界面不靠轮询等状态，让守护进程推。** 图标原来只由 App 自己的定时器驱动，
拔线到变暗最多要等一个轮询周期。现在每次状态转变（共享起停、relay 起停、DNS 重新下发、
自动模式开关、发现陌生设备）都会**原地重写** `$TMPDIR/MacToAndroid/changed`，
App 用 kqueue（`DispatchSource` 的文件系统事件源）盯着它，收到就立刻刷新——
实测写一次戳，App 在 200 毫秒内就起了一次 `summary`，而不动它的对照窗口里它完全不动。
守护进程还会在**收到设备事件的第一时间**就打戳（早于对账），所以插拔的反应不用等对账跑完。

三个坑：

- kqueue 盯**目录**只在增删条目时触发，改文件内容不算。所以只能盯文件本身，
  写入方也必须原地截断重写（inode 不能变）——用 create+rename 那边就收不到通知。
- `$TMPDIR` 会被系统清理。文件被删掉之后旧 fd 指向的 inode 再也不会有人写，watch 就
  **静默失效**。所以 delete / rename / revoke 都要重新武装；此外每次轮询还做一次自检——
  戳文件的 mtime 比收到的最后一次通知还新（且已超过 2 秒，排除「通知还在路上」），
  就说明这个 watch 不灵了，直接重装并补一次刷新。有了自检，watch 失效不再是
  「静默降级成轮询」而是会被自动修好，轮询周期也就可以从 10 秒放宽到 **30 秒**
  （唤醒次数只有原来的三分之一）。它现在只负责三件推送覆盖不到的事：watch 自检、
  守护进程死了的告警、以及「插着但 adb 读不到 / 未授权 / 依赖缺失」这类不产生 adb 事件的状态。
  实测：删掉戳文件 → App 3 秒内重建并盯上新 inode（`lsof` 可见 inode 变了）→ 推送照旧生效。
- 推送和轮询会同时触发两次刷新，先发的后到就会把旧状态盖回去、闪一下。所以刷新带一个
  generation 计数，只认最新那一次的结果。

**不给「变暗」加宽限期。** 烂线抖动时图标会闪，这是有意的：宁可闪一下，也不要出现
「界面写着共享中，而手机其实没网」——后者用户根本无从判断。250 毫秒的合并窗口只是
把连续通知合成一次刷新，不改变任何状态的呈现时机。

**打开菜单时顺手同步图标。** `menuNeedsUpdate` 本来就取了一份新的 summary 用来画菜单，
却没拿它更新图标，于是图标要等下一次定时器才对得上。

**「共享中」的台数只数还插着的设备。** `active` 里的记录在拔线后会残留一小会儿
（宽限期内、或等下一次对账），`summary` 若照抄它的条数，菜单栏图标会在设备早已拔掉之后
继续亮着——用户看到的就是「明明拔了却还显示连接中」。现在 `shared=` 只数
`active ∩ 在线`，与 `status` 把不在线的设备算作 `offline` 保持一致；菜单栏图标的兜底刷新
也从 20 秒缩短到 10 秒（拔线到图标变暗最多 10 秒）。

**离线设备不给逐台操作入口。** 之前离线行也有「开始共享」和「不再询问」，但它们只是预先
写一条 allow / deny 记录，界面上没有任何可见变化——看起来就是按钮坏了。现在离线行只显示
「请连接设备」。设备不在场时要改记录，用 CLI：`mta-ctl allow / deny / forget <serial>`。

**`resolve` 也要加锁。** 它重写 `pending-ask`（读→写 tmp→mv），而守护进程的 `queue_ask`
在锁内往同一个文件 append。App 回答完 A 的同一刻 B 排进来，B 就会被覆盖掉——而 B 已经写进
`asked`，本次连接内不会再问它，于是它既不共享也没有任何提示。

**守护进程状态会暴露给界面。** 插线自动共享全靠守护进程。它若被卸掉或崩溃，
界面仍会显示「自动模式：已开启」而实际什么都不会发生，用户无从察觉。
所以 `summary` 里有 `daemon=up/down`，菜单和窗口会显示
「⚠ 守护进程未运行」并给一个「重新启动守护进程」的入口。

**Ctl 调用有超时且不留未读管道。** `adb` 在设备状态异常时会挂住，而菜单构建发生在
主线程，没有超时会把整个应用卡死；`standardError` 若设成一个从不读取的 `Pipe`，
缓冲区（约 64KB）写满后子进程会永久阻塞。前者用 watchdog 强制 `terminate`（实测
挂住 30 秒的命令在 2 秒超时下 2.17 秒返回），后者丢到 `FileHandle.nullDevice`。

**禁用按钮的时长不能等于超时时长。** 上面把改状态的调用放宽到 90 秒之后，
`busy` 期间按钮全灰——adb 真挂住时用户要盯着一个「死掉的界面」等 90 秒。
现在 8 秒后就把按钮放开，并在告警行（菜单里是一个禁用项）写明「上一个操作还在处理」，
操作继续在后台跑完，结果回来时再刷新一次。用一个自增 token 区分先后，
避免慢操作回来时把新操作的状态覆盖掉。

**`why` 要用更短的超时。** 菜单构建在主线程上，而每台 `allowed-idle` 的设备都会多一次
`why`（内部是几次 adb 往返）。adb 卡住时按默认 8 秒算，三台卡在待启动的设备就是
八秒乘五的界面冻结。`why` 只是诊断信息，给它 3 秒，宁可这次拿不到。

**这个超时之所以是硬上限，是因为只读子命令没有装 TERM trap。** bash 在等前台子进程
（adb）时收到 TERM，**有** trap 就会把信号压到子进程结束之后才处理。实测：

```
没有 TERM trap 的脚本 → TERM 后 0.0 秒结束
有   TERM trap 的脚本 → TERM 后 4.6 秒仍存活（在等 sleep 30）
```

所以「挂住 30 秒的命令在 2 秒超时下 2.17 秒返回」这条成立的前提就是没有 trap。
这轮我一度想给 ctl 加个 TERM trap 去回收 adb 子进程，**结果正是把这个机制废掉了**，
已经撤销。代价是被杀时 adb 会变成孤儿（它自己会跑完）、锁目录留在原地
（由「持有者已死」检测回收）——这两个代价比「界面被拖到 adb 自己结束」小得多。

改状态的子命令由 `acquire_lock` 装了 `trap release_lock EXIT INT TERM`，
它们因此**不可被及时打断**——但那是对的：锁必须持有到 adb 真的结束，
否则对账会和安装并发。两类子命令的行为差异是有意的。

**但改状态的调用不能用同一个超时。** 默认的 8 秒是给 `summary` / `status` 这类
读操作的（它们跑在主线程上，卡住就是整个应用卡住）。而 `auto on` 要对每台设备走一次
`client_start`：relay 起来最多 5 秒、等客户端真的连上最多 6 秒，之前还可能排队等锁最多
30 秒。8 秒会在中途被 watchdog 杀掉，界面弹「控制器执行失败」——**而 `enabled` 标记
其实已经写了，状态确实变了**，比真失败更让人困惑。所以 `perform()` 这条路径用 90 秒，
它本来就跑在后台线程，不影响界面。

**显式路径必须自己检查条件，不能依赖 `allow` 的退出码。** `reconcile` 会**故意**吞掉
`client_start` 的失败（`client_start "$s" >/dev/null || true`）——自动路径必须静默，
插线充电不该被弹窗打扰。代价是 `allow` 也返回 0，调用方无从得知失败。

于是出现过这样的 bug：插入新设备 → 点「共享」→ 界面显示「已允许·待启动」→ 然后什么都不发生、
不给任何原因。真实原因只在日志里：`跳过: 手机端未安装客户端`。

修法是两层：
- `mta-ctl` 提供 **`why <serial>`**，把 `preflight` 的回显暴露出来
- 界面在渲染 `allowed-idle` 行时调用它，把原因拼进标签：
  `待启动（手机端未安装客户端）` 而不是光秃秃的「已允许·待启动」——后者暗示
  "马上就会启动"，而真实含义可能是"因为某个原因永远不会启动"

**自动模式是总开关，`preflight` 必须知道它关着。** 关闭自动模式后点某台设备的
「开始共享」，走的是 `allow` → `reconcile`，而 reconcile 第一件事就是 `stop_all` 然后返回
——什么都不会启动。但 `preflight` 原来不看这个开关，于是：`allow` 照样把它写进允许列表 →
`status` 报 `allowed-idle` → 界面把 `allowed-idle` 当成「开着」、按钮翻成「停止共享」→
**而手机上根本没有 VPN**。更糟的是引导层等 8 秒没等到 `shared`，会把原因猜成
「请在手机上允许 VPN 连接」——一个完全错误的诊断，用户照着去手机上找根本不存在的授权框。

四处一起修：

- `preflight` 加一条 `[ -f "$FLAG" ] || echo "自动模式已关闭"`，于是 `why` 能如实回答，
  设备行显示「待启动（自动模式已关闭）」。
- 引导层新增 `.autoOff` 分支：直接问「要开启自动模式并共享吗」，确认后 `auto on` 再重试。
- **`allowAndVerify` 改成「先问 why 再猜」。** 原来的顺序是先翻 relay 日志、再猜 VPN 授权，
  最后才拿 `why` 兜底——任何 preflight 已经知道的原因都会被前面的猜测抢先答错。
  这个顺序问题是通用的：**有权威答案时不要先猜。**
- 按钮文案区分开：`shared` → 「停止共享」，`allowed-idle` → 「取消共享」。
  对一个什么都没在跑的设备说「停止共享」，正是「手机上没 VPN、按钮却写着停止共享」的来源。

实测（真机）：关闭自动模式 → `status` 变 `allowed-idle`、`why` 输出「自动模式已关闭」；
重新开启后立刻回到 `shared`、`relay=up`、`tunnel=ok`。

**每一步失败都要给出下一步。** 安装手机端客户端这条链上，原来只有「小米拦截」有退路，
其他原因失败就弹一句 adb 的英文输出然后关掉——用户拿着
`INSTALL_FAILED_INSUFFICIENT_STORAGE` 无从下手，连「还能推送到手机手动装」这条路都不知道。
现在每条失败路径都有出口：

| 失败 | 出口 |
|---|---|
| `INSTALL_FAILED_USER_RESTRICTED`（小米「USB 安装」未开） | 推 APK 到手机 + 打开手机的「下载」界面 |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` / 签名不一致 | 「卸载旧版并重新安装」（`mta-ctl uninstall-client`） |
| 其他（存储不足、设备掉线、空输出…） | 「推送到手机手动装」/「打开开发者选项」 |
| 连推送也失败 | 「在访达中显示安装包」（`mta-ctl apk-path`），提示用 AirDrop / MTP 传过去 |

**签名冲突要单独一条路，而且判定必须排在「包是否存在」之前。** 手机上装过来源不同的
gnirehtet 客户端时，Android 不允许用另一个签名覆盖安装。而 `install_client` 原来
「结果以实际包状态为准」——包确实在（是那个旧的），于是被判成**安装成功**，
接着卡在「版本不一致」上，而重装又是同样的失败，用户永远出不来。
这种情况**推送手动装也没用**，手机会直接报「应用未安装」，所以只能先卸掉旧的。

`uninstall_client` 要求设备在线才动手：设备不在线时 `adb uninstall` 会失败、
`client_installed` 也查不到，于是「查不到」被当成「已卸掉」——和 `heal` 踩过的是同一类坑。

**手机上撤销 VPN 授权之后，`preflight` 查不出任何问题。** 用户在手机上删掉「保存的 VPN
配置」之后：客户端装着、版本一致、设备在线——`preflight` 全过，但 `am start` 拉起客户端时
Android 要重新弹一次「连接请求」授权框，没人点它就永远建不起 VPN。于是 `why` 输出空，
界面只显示光秃秃的「已允许·待启动」，而用户唯一能把授权框撞出来的办法是
「停止共享 → 开始共享」——像是必须念对咒语才启动得了。

现在 `client_start` 在「确认客户端没跑起来」时会写一个 `$TMPDIR/…/needvpn.<serial>` 标记，
`why` 据此回答「手机上的 VPN 连接请求未确认」，设备行上会显示它并给出「解决问题」入口，
引导层直接说明要在手机屏幕上点确认，点完「已允许，重试」即可。标记在成功启动或停止共享时
清掉。`heal`（每 5 分钟）也会重试一次 `gnirehtet start`，所以在手机上点了确认之后就算不管它，
最多 5 分钟也会自己恢复——代价是授权框会每 5 分钟再弹一次，直到点掉或停止共享。

同一件事还有另一种形态：**共享期间**在手机上撤销授权。此时 `active` 会一直谎报「共享中」，
而隧道检查（`adb reverse`）照样是 ok 的，界面上完全看不出问题。所以 `heal` 除了查客户端还在不在，
还会查它的服务是不是真的在跑，不在就移出共享列表，让下一次对账走完整路径重新拉起。
判据要保守：`dumpsys activity services` 即使一个服务都没有也会打表头（`(nothing)`），
所以只有**回显非空且不含 `ServiceRecord`** 才敢断言「没在跑」——回显为空只可能是 adb 抽风，
那种情况按「还在跑」处理，宁可少动一次，也不要把一个好好的共享掐掉。

**用户主动操作时必须引导，自动触发时必须静默。** 这两条不能混。`Guide.swift` 承担
显式路径的引导：`ctl why` → 解析成具体问题 → 弹对应对话框并执行修复 → 重查（最多 4 轮）。
覆盖手机端未安装客户端、版本不一致、缺 gnirehtet/adb、设备离线、模拟器、
「仅无网时接管」、手机上的 VPN 连接请求未确认、`WRITE_SECURE_SETTINGS` 八种情形，
以及安装被小米拦截（`INSTALL_FAILED_USER_RESTRICTED`）这个已知坑。

**`WRITE_SECURE_SETTINGS` 那一支曾经永远命中不了。** 它只出现在 `gnirehtet start` 的回显里
（那条命令内部跑的是 `adb shell am start`），而所有 `gnirehtet start` 都被
`>/dev/null 2>&1` 丢掉了，引导层却去 `relay.log` 里 grep 它——`relay.log` 只由 relay 进程写，
那里永远不会有这个串。于是用户拿到的永远是泛化的「已允许，但没有连上」。
现在 `gnirehtet_start_one` 会把最后一次启动的回显存进 `$TMPDIR/…/laststart.<serial>`
（`mta-ctl last-start <serial>` 可读），启动失败时据此区分「VPN 授权没点」和
「安全设置没开」，两条路径（`why` 与「开始共享」后的确认）都用同一份判据。

全流程异步：安装 APK 可能要几十秒，同步跑会把菜单栏卡成转圈。

> 改写 UI 时最容易整层丢掉的就是这种「只在异常路径上跑」的代码：它不影响任何正常流程，
> 编译也不会报错，只有真的撞上异常才会发现它不见了。

**`brew upgrade gnirehtet` 之后，跑着的 relay 还是旧二进制。** Homebrew 的 `bin/gnirehtet`
是个 wrapper，exec 的是 `Cellar/gnirehtet/<版本>/libexec/gnirehtet`。升级之后：relay 进程
仍是旧版本（inode 还在、路径已经没了），而 `mac_apk_version` 已经变成新版 →
preflight 判「版本不一致」→ `try_fix_version` 把**新版 APK** 装到手机上。
结果是新版手机端 ↔ 旧版 relay，症状就是那个最难查的「手机 VPN 亮着但一个包都过不去」。

所以 relay 启动时把当时的 `mac_apk_version` 记进 `$STATE_DIR/relay.ver`，心跳比一次，
不一致就重启 relay（`mac_apk_version` 只读一个 wrapper 脚本、不碰 adb，成本可忽略）。
实测：把 `relay.ver` 改成假版本号，心跳如实记下「relay 由旧版本 gnirehtet 启动」并重启，
之后 `relay=up`、`tunnel=ok`、`relay.ver` 回到真实版本。

**「仅无网时接管」的语义必须持续成立。** `has_own_network` 原来只在 `preflight` 里调用，
也就是只在**接管那一刻**判一次。手机中途连上自己的 Wi-Fi 之后，流量仍然全走 VPN
——仍然在用 Mac 的网，正是这个开关想避免的事。现在 `heal`（每 5 分钟）会检查在共享的设备，
发现它有自己的网络就释放；释放之后 `preflight` 会拦住重新接管，等它真的又没网了才接回来。
不需要额外防抖——5 分钟的采样间隔本身就是防抖。

**永久卡住的设备会把日志刷爆。** 心跳里有一条「已允许、在线、但没在共享 → 再对一次账」，
用来自愈开机时的首次对账失败。但如果一台设备是**永久**卡住的（客户端没装、手机自己有网），
这条就变成每 20 秒对一次账、每次写一行「跳过: …」——一天上万行，把真正的事件冲掉。
两处限制：对账本身限速到 60 秒一次（幂等，慢一点无害），「跳过」的日志按原因去重
（原因变了才记，和 `IGN_SIG` 同一个套路）。

**`active` 会谎报「共享中」。** 快路径为了省时间跳过 `preflight`，所以客户端被卸载
或被系统清理后，`active` 里的记录一直存在，界面持续显示「共享中」而实际不通。
`heal`（每 5 分钟）会顺手查一次 `pm list packages`，客户端不在就移出共享列表——
让状态自己纠正，而不是在每次渲染时付这个成本。

**但「进程被系统杀掉」必须放进 20 秒心跳，不能等 heal。** 手机端进程被清理不是异常，
是**常规事件**：HyperOS 的「锁屏后清理内存」每次锁屏都会杀一次，logcat 里是
`am_kill … stop com.genymobile.gnirehtet due to LockScreenClean`。实测一次这样的掉线
恢复要 **332 秒**——10:38:10 进程被杀（relay 0.6 秒后记下 `Client #0 disconnected`），
10:43:12 heal 才发现并移出共享列表，10:43:42 才重新起来。两段延迟叠加：
`heal` 的 300 秒 + 心跳量化，再加上 heal **只移出、自己不拉起**，得再等一次心跳。

为一个每天发生多次的常规事件等 5 分钟不值，所以这项检查移进了心跳，上限压到
一个心跳（20 秒），而且发现和重新拉起在同一轮里完成。它必须放在 `health` 的**最前面**
——后面那些分支都会 `return`，排在它们之后就会被跳过。

实测（`adb shell am force-stop com.genymobile.gnirehtet`）：

```
14:22:28.014  am_kill  gnirehtet  adj=200  "due to from process:18306"
14:22:28.434  relay    Client #0 disconnected                       (+0.4s)
14:22:45      ctl      手机端客户端没在运行…移出共享列表
14:22:45      ctl      有已允许但未共享的设备，触发对账              ← 同一秒、同一轮 health
14:22:47.502  relay    Client #1 connected                          (+19.5s)
```

**19.5 秒**，对照改动前 330 秒。那三行落在同一秒说明发现与重新拉起在同一轮里完成，
不用等下一次心跳——这就是把扫描排在最前面的收益。判据走的是「服务在不在」而不是
「谁杀的」：这次的 `am_kill` 理由是 `from process:…`、adj=200，和 `LockScreenClean`、
adj=50 完全不同，两种都能兜住。

**「放进心跳太贵」这个顾虑是错的，实测才发现。** 起初想为此另写一个便宜的 `pidof` 判据，
理由是 `dumpsys` 慢。同一台设备交错各测 8 次取中位，结论正好相反：

| 探测 | 中位耗时 |
|---|---|
| `dumpsys activity services <pkg>` | **74 ms** |
| `pidof <pkg>` | 87 ms |
| `pm list packages <pkg>` | 90 ms |

三者同一个量级，`dumpsys` 还是最快的那个。于是那个新判据整个删掉了，直接复用现成的
`client_definitely_dead`——它顺带还能覆盖**「进程活着但服务没在跑」**（用户在手机上撤销或
删除了保存的 VPN 配置），而 `pidof` 在那种情况下会如实报告「进程还在」、什么也发现不了。
少写一个判据、覆盖面更宽、还更快。

**移过去之后 heal 里那份就删了。** `heal` 的每一次调用都发生在一次心跳里，`health` 必然
已经先跑过同一项，留着就是一段永远不会命中的死代码——而没人跑的分支一定会腐烂。
heal 里保留的是 `pm list packages`（客户端被**卸载**），那是用户主动行为、罕见，
300 秒的周期够了。

**宽限期必须有东西在期满后重新评估。** 拔线通常只产生**一个**设备事件，那次对账
只打了「暂时消失」标记就返回。如果心跳在「relay 正常、隧道正常」时直接跳过对账，
这个标记就永远得不到重新评估——**线已经拔了，界面却一直显示「共享中」**。
所以心跳发现有 `missing.*` 标记时必须触发一次对账。这是加宽限期时引入的回归。

**心跳能自愈「首次对账失败」。** 开机时手机可能还没授权完，首次对账会失败。
如果心跳只在「已有设备在共享」时才动作，这种情况就只能靠用户拔插恢复。
所以心跳还会检查「已允许、在线、但没在共享」的设备，有就再对一次账。

**这条恢复分支不能包在「active 为空」里——多设备时那样是坏的。** 早期版本把它写在
`if active 为空` 的分支内部，两台设备同时共享、其中一台的客户端被系统杀掉之后：
`heal` 把它移出 `active`、自己不重新拉起；下一轮 `heal` 又只遍历 `active_list`
（它已经不在里面了）；而这条恢复分支被「active 不为空」挡在门外。于是**只要没有设备
事件、也没有别的异常（relay 挂、fd 耗尽、隧道断），那台设备永远不会恢复**。
单设备之所以一直没暴露，纯粹因为移出后 `active` 恰好变空、正好命中了那条分支。

改成无条件检查 `pending_starts`。但**被 60 秒限速挡住时必须继续往下走，不能 `return`**：
永久卡住的设备（客户端没装、手机自己有网）会让 `pending_starts` 一直非空，在那里返回
等于把 relay / fd / 版本 / 隧道那些检查全部永久饿死——原来的写法之所以可以直接
`return 0`，是因为它只在「没有任何设备在共享」时才会走到，后面本来也没什么可查。

**dumpsys 解析失败按「保守」处理。** 「手机是否已有网络」的判断依赖 `dumpsys connectivity`
的格式，跨 Android 版本会变。匹配不到时按「没有自己的网络」处理——宁可多接管一次，
也不要因为解析失败而静默不工作。

## 发布前需要你决定的

~~**图标里有 Apple 标志和 Android 机器人。**~~ **已决定不换。** 记录一下事实以免以后重新纠结：
Apple 的品牌指南禁止在应用图标里使用 Apple 标志，Android 机器人是 Google 的商标
（形象按 CC-BY 授权、需署名），项目名同时含 "Mac" 和 "Android" 两个商标——
这些规则与是否收费无关，免费开源同样适用。作为自用 / 非商业的开源小工具，
作者判断这个风险可以接受。真要规避，换成笔记本剪影 + 手机剪影就能表达同样的意思。

~~**没有 LICENSE。**~~ 已选定 **Apache-2.0**（见下方「许可证」一节）。

**界面全是中文。** 如果面向国际用户，需要英文版 README 和界面文案。

## 被误杀之后会怎样

各组件被别的程序或手动杀掉后的恢复路径，都实测过：

| 被杀的东西 | 恢复方式 | 实测延迟 |
|---|---|---|
| **adb server**（Android Studio、scrcpy 都会 `adb kill-server`） | 写端退出补的哨兵即时触发 → 3 秒退避后重连 → 首帧就是权威列表 → 对账 → 重建 `adb reverse` 隧道与 client | **约 3 秒** |
| **relay 进程** | 心跳发现 `relay 已不在` → 对账重启 | ≤20 秒（心跳间隔） |
| **手机端客户端**（HyperOS「锁屏后清理内存」每次锁屏都会杀，`am_kill … due to LockScreenClean`；用户在手机上撤销 VPN 配置也走这条） | 心跳里 `client_definitely_dead` 发现 → 移出共享列表 → 同一轮对账重新拉起 | **实测 19.5 秒**（`am_force_stop` 验证；改进前那次 LockScreenClean 是 **330 秒**） |
| **守护进程** | launchd `KeepAlive` 拉起 | **3 秒** |
| **守护进程的 LaunchAgent 被卸载** | 不会自动恢复。界面显示「⚠ 守护进程未运行」并提供「重新启动守护进程」 | 需手动 |
| **菜单栏 App** | 不自动重启。**共享不受影响**，守护进程独立运行 | 需手动打开 |

菜单栏 App 刻意不做 `KeepAlive`——否则菜单里的「退出」会被立刻拉回来，那个按钮就没意义了。
它挂了只是没界面，共享照旧。

`adb kill-server` 这条最值得注意：它会一并带走 `adb reverse` 隧道，此时 relay 和手机端
client 可能都还「活着」，但两者之间的通道断了。恢复日志：

```
16:46:50  adb kill-server → Client #1 disconnected
16:46:50  守护进程: track-devices 中断，3 秒后重连
16:46:55  守护进程: 设备状态变化 → 对账
16:46:56  Client #2 connected
```

## 排障

### 手机插着但 `adb devices` 看不到

先看 App 有没有提示「⚠ 检测到 Android 设备，但 adb 读不到它」。有这条说明
**macOS 看到手机了，是 adb 读不到**——不要去查开发者选项，那个方向是错的。

原理是比对 `ioreg` 里有没有 `ADB Interface` 与 `adb devices` 是否为空。两者矛盾时
adb 的日志长这样：

```bash
adb kill-server && ADB_TRACE=usb adb nodaemon server 2>&1 | grep -i serial
# failed to get serial from device 1-1 : LIBUSB_ERROR_IO
# Can't init address='usb:1-1', serial=''
```

设备枚举成功但读取序列号的 USB 控制传输失败，这是 **USB 半死状态**，
多见于睡眠唤醒之后。**拔掉数据线再插上**即可，重启 adb server 没用
（问题在 USB 控制传输层，不在 adb 进程状态）。

### 连接反复自动断开

查两个手机端属性：

```bash
adb shell dumpsys battery | grep 'USB powered'
adb shell getprop sys.usb.config
```

正常应是 `USB powered: true` 和 `mtp,adb`。如果是 `false` 和 `none`——
插着线却报告未被 USB 供电、gadget 配置为空——那是**线材或接口接触不良**，
换线（优先原装数据线）或换 USB 口，别经过扩展坞，并检查手机接口是否积灰。

统计闪断频率：

```bash
grep -c '设备状态变化' ~/Library/Logs/MacToAndroid/watcher.log
grep -c 'Client #.*connected' ~/Library/Logs/MacToAndroid/relay.log
```

工具侧已有 8 秒宽限期和幂等快路径，能吃掉大部分抖动而不断隧道；
但物理层的问题只能换线解决。

### 手机上 VPN 亮着但没有网络

`adb reverse` 隧道断了（多因 USB 重新枚举），但手机端 VpnService 还在，
所以看起来一切正常。菜单里会显示「⚠ 隧道已断，手机有 VPN 但没网」，
点「立即修复隧道」即可；也可以：

```bash
"$HOME/Library/Application Support/MacToAndroid/mta-ctl.sh" repair-tunnel
```

手动确认：

```bash
adb reverse --list        # 应有 UsbFfs localabstract:gnirehtet tcp:31416
```

正常情况下 20 秒内心跳会自动修复，不需要手动干预。

### 手机 VPN 亮着、隧道也正常，但一个包都过不去

relay 的文件描述符耗尽了。菜单会显示「⚠ relay 文件描述符耗尽，正在丢包」，
心跳会在 20 秒内自动重启它。手动确认：

```bash
tail -200 ~/Library/Logs/MacToAndroid/relay.log | grep 'Too many open files'
```

正常情况下不该出现——`FD_LIMIT` 已设为 8192。若仍出现说明连接泄漏得更快，
可以调高 `mta-ctl.sh` 里的 `FD_LIMIT`（`kern.maxfilesperproc` 上限通常是 61440）。

### 什么都不对时

```bash
"$HOME/Library/Application Support/MacToAndroid/mta-ctl.sh" doctor
```

一次输出依赖位置、APK 路径、状态目录、App 路径、端口占用、USB 状态与建议。

## 已知限制

- **不转发 ICMP**，`ping` 不通但正常上网不受影响，这是 gnirehtet 的设计。
- **拔线时手机端 VPN 不会自行结束**，钥匙图标会一直挂着且手机上不了网。
  插回线后由 Mac 侧的 `gnirehtet stop` 清掉——这就是启动流程里先 stop 再 start 的原因。
- **睡眠 / 唤醒**：实测睡了 2.5 小时后唤醒，launchd 重启守护进程并对账，
  系统收敛到正确状态（设备已不在，于是停掉共享与 relay）。但没有测过
  「睡眠期间设备保持连接」的情形——那种情况下 USB 是否重新枚举取决于硬件。
- **手机所有流量经过 Mac**，Mac 上可以抓到明文。自用无妨，公用机器上注意。
- **多设备只在单机单设备环境下推演过**，没有真的插两台测过。其中一个具体缺陷已经修掉
  （心跳的恢复分支原来被「active 为空」挡住，多设备时单台客户端被杀后不会恢复），
  但那是靠读代码发现的，同样没有双机实测。
- **测试询问流程**：`forget <serial>` 之后**拔下再插上**。单独 `forget` 不会弹窗
  （见「设备策略」里的说明），必须有一次真实的断开重连才会重新询问。
- **抢不到锁的对账会被丢掉。** 锁最多等 30 秒，超时就放弃本次操作。如果设备插拔正好
  撞上一次耗时较长的 `heal`，这个事件会被丢弃，要等下一次心跳（最多 20 秒）才收敛。
  `health` 现在会检查「共享列表里的设备是否还在线」，能兜住其中最要紧的一类。
  安装手机端客户端最长会占着锁几十秒（`install-client`），这段时间的事件同样会被丢掉。
- **离线设备只能用 CLI 改记录。** 界面上离线行只显示「请连接设备」，
  预先允许 / 拒绝 / 清除记录要用 `mta-ctl allow|deny|forget <serial>`。
- **两台序列号相同的设备无法区分。** 部分廉价设备出厂序列号是重复的
  （例如 `0123456789ABCDEF`），adb 本身就分不清，允许/拒绝列表按序列号存储，
  会同时作用于它们。
- **`asked` 记录按连接重置**（离开超过 8 秒才算真正断开）。同一次连接内对一台
  陌生设备只问一次；重新插上会再问。`forget` 不会重新武装询问。
- **多用户 / 快速用户切换没有处理。** 同一台 Mac 上两个登录用户各自跑一份守护进程时，
  它们共用同一个 adb server，会对同一台设备互相抢 client。端口冲突有兜底（会自动换、
  也不会去杀别的用户的 relay），设备级没有。
- **模拟器过滤与「未授权」计数用合成数据测的**：本机没装 Android SDK 模拟器，所以 `usb:` 字段的
  判别逻辑是用伪造的 `adb devices -l` 输出（含模拟器、无线调试、未授权、离线四类）
  验证的，没跑过真的模拟器。

## 改完随手跑

```bash
./check.sh
```

全是静态检查加只读子命令，不动任何状态。它挡的是**只在某个环境下现形、既不会让
`bash -n` 失败也不会让编译报错**的那类问题——这个项目被咬过好几次的都是这种：

| 检查 | 挡住的是 |
|---|---|
| `bash -n` / python 语法 / swiftc（**警告也算不通过**） | 常规错误；零警告是这个项目一直保持的状态 |
| 变量名紧跟全角字符 | UTF-8 locale 下 bash 3.2 会报 `unbound variable`——而 `LANG` 未设置时完全正常，所以本地测不出来 |
| 界面调用的子命令是否都存在 | 界面调了一个不存在的 `mta-ctl` 子命令：`Ctl.run` 只会返回 nil，界面静默地什么都不做 |
| 引导层判据与 `mta-ctl` 文案是否一致 | 引导层靠中文子串和 `ok`/`restricted`/`incompatible` 这些 token 识别原因，`mta-ctl` 里的文案一改就静默失配——改 UI 时最容易丢的正是这类联系 |
| 版本号一致 | `build.sh` 与 `mta-ctl.sh` 各写一份版本号，对不上会让 `doctor` 和界面互相矛盾 |
| UTF-8 locale 下的只读子命令冒烟 | 上面那条静态扫描漏掉的 locale 相关问题。**按 stderr 形态判定，不只看退出码**——见下 |

**冒烟这一项不能只看退出码。** 早期版本是「退出码非 0 就算不通过」，结果 CI 上必挂：
runner 不装 gnirehtet，`mta-ctl apk-path` 如实返回 1 并打印「找不到 gnirehtet.apk」，
被当成 locale 问题拒绝出包，`release.sh` 停在源码检查那一步——**tag 打了、Release 没出**。

这个失败在本机怎么都复现不出来，原因值得记下：`mta-ctl.sh` 一开头就**自己重建 PATH**
（第 30 行起，因为 launchd 给的 PATH 太干净，不重建就找不到 brew 装的东西），
调用方的 PATH 根本不参与。所以「把 brew 从 PATH 里摘掉再跑」这个对照**从原理上就无效**
——我用它验过一遍 CI 可行性并得出「全部 exit 0」的结论，那个结论是假的。
要模拟「依赖没装」只能让二进制在文件系统上消失，本机做不到。

现在按 stderr 的形态区分两类非 0：bash 自己崩掉带行号
（`./mta-ctl.sh: line 202: APP?: unbound variable`）算不通过；脚本自己打印的干净消息
（「找不到 gnirehtet.apk」）只记一条 note。用桩脚本三向验过：全 0 → 全 ok；
依赖缺失 → note 且不置失败位；`set -u` 下的未定义变量 → 判失败并打印原文。

**这些探测器本身也被反向验证过**：往副本里逐个注入对应的错误（全角变量、不存在的子命令、
改掉引导层判据、改版本号、加一个用不到的变量），五条全部被抓到并指名道姓；恢复后干净通过。
一个没测过的守卫等于没有守卫——这轮就是因为我自己又写了一次 `$rver（` 才决定把它做成脚本。

`release.sh` 出包前会先跑 `check.sh`，源码层的门槛只有这一份实现，不会两处漂移。

## 发布

```bash
./release.sh              # 出包 + 自检，打印后续命令
./release.sh --publish    # 额外调 gh 直接创建 GitHub Release
```

`release.sh` 做四件事，每一件都是踩过或差点踩到的坑：

- **版本一致性**：版本号写在两处（`build.sh` 打进 Info.plist、`mta-ctl.sh` 自己 report），
  对不上会让 `doctor` 和界面显示的版本互相矛盾，所以发版前先卡住。
- **产物自检**：通用二进制（缺架构直接拒绝出包）、签名有效、包内带着两个脚本和
  LICENSE / NOTICE、没有写死的用户路径。
- **用 `ditto` 而不是 `zip`**：`zip` 不保留扩展属性和符号链接，`.app` 压完再解开签名会坏，
  对方双击报的是「应用程序已损坏」——比「无法验证开发者」更难查。出包后还会解开来
  **重新验一次签名**，确认压缩没破坏包结构。
- **生成发布说明**：依赖安装、Gatekeeper 的正确做法（见上）、sha256 校验和。

打包用的是 `./build.sh --no-install [目录]`：只生成 `.app`，不铺开脚本、不注册 LaunchAgent。
CI 里必须走这条——GitHub Actions 的 runner 上 `launchctl bootstrap` 会失败，
而 `build.sh` 是 `set -e`，会中断整个构建、出不了包。

仓库里有 `.github/workflows/release.yml`：推 `v*` 标签就自动构建、自检、发 Release
（zip 与 `mactoandroid.rb` 一起挂上去，后者的 sha256 正对应这次发布的包）。
不想用 CI 的话删掉即可，`release.sh` 在本地一样能跑完全套。

### Homebrew Cask

`release.sh` 会顺手生成 `dist/mactoandroid.rb`，**版本号和 sha256 自动填好**——
手抄这两样是最容易出错的一步，而 sha256 错了用户侧直接装不上。用法：

1. 建一个叫 `homebrew-mactoandroid` 的仓库（brew 要求 tap 仓库以 `homebrew-` 开头）
2. 把 `mactoandroid.rb` 放进该仓库的 `Casks/`——**必须是发版那次构建产出的那一份**：
   走 CI 发版时它作为 Release 资产挂在 zip 旁边，本地发版时在 `dist/` 里。
   事后重跑一次 `release.sh` 生成的那份，sha256 算的是你本地新构建的 zip，
   和 Release 上挂的包不是同一个字节（runner 与本机的 Xcode 版本不同），用户侧直接校验失败。
3. 之后每次发版重复第 2 步

用户侧：

```bash
brew tap daily-units/mactoandroid
brew trust daily-units/mactoandroid
brew install --cask --no-quarantine mactoandroid
```

**`brew trust` 是新版 Homebrew 要求的**：第三方 tap 里的 cask 默认不加载，
`brew info --cask` 都会被拒。用 `brew untrust` 撤销信任后可复现这个拒绝——
验过，不是猜的。

**`--no-quarantine` 是必要的**：Homebrew 默认会给下载的应用**加上**隔离标记
（不是去掉），而这个 App 未经公证，所以不加这个参数首次打开仍会被 Gatekeeper 拦。
cask 的 `caveats` 里也写了 `xattr -dr` 那条退路。

cask 里值得注意的两处：`depends_on formula: "gnirehtet"` + `depends_on cask:
"android-platform-tools"` 让依赖能自动装；`uninstall launchctl:`/`trash:` 显式清理两个
LaunchAgent 和运行目录——**不写的话 brew 也只会删掉 `.app`，守护进程会留下**。
`zap trash:` 才是用户数据（设备列表、日志）。生成的文件跑过 `brew style --cask`，零告警。

## 许可证

**Apache-2.0**，Copyright 2026 Waldron。完整原文见 [LICENSE](LICENSE)，
`NOTICE` 是 Apache-2.0 约定的署名文件，两者都会被 `build.sh` 复制进 `.app`
（第 4(a) 条要求随作品附上一份 License）。每个源文件顶部有 SPDX 短声明。

**和 gnirehtet 的关系是「调用」，不是「包含」。** 本项目不含 gnirehtet 的任何代码、
二进制或 APK——它通过 shell 启动 `gnirehtet` 这个独立进程，APK 路径是从用户自己安装的
那一份里读出来的。调用独立程序不产生衍生作品，所以本项目的许可证与 gnirehtet 的
Apache-2.0 互不约束（这里选 Apache-2.0 是为了和上游一致，不是被迫）。

如果以后为了免掉 brew 依赖把 `gnirehtet.apk` 或它的源码打进包里，那部分**仍然必须保持
Apache-2.0**，要带上它自己的 `LICENSE` 与 `NOTICE`、并标注改动——不能改写成别的许可证。

选 Apache-2.0 而不是 MIT 的理由：它多了明确的**专利授权**与专利报复条款、明确声明
**不授予商标权**（这个项目名和图标本来就踩在商标灰区上，写清楚有好处），
以及贡献默认同许可证。代价是要多维护一个 `NOTICE`、改动过的文件要标注。
注意它**与 GPLv2 不兼容**（与 GPLv3 兼容）。

## 文件

```
MenuBar.swift              菜单栏前端（主）：状态图标 + 菜单 + 陌生设备询问
Guide.swift                引导层：条件不满足时逐项弹窗解决（仅显式路径）
Notify.swift               操作完成通知（菜单关闭后唯一的反馈途径）
Window.swift               原生主窗口：设备列表与逐台操作
Installer.swift            首次运行自装：铺开脚本、注册 LaunchAgent
mta-ctl.sh                 核心控制器，App 与守护进程共用
watcher.sh                 守护进程，只负责监听事件并触发对账
icon.png                   图标底图（带 alpha 的正方形 PNG）
make-icon.py               图标处理：把带 alpha 的底图转成满幅不透明图（build.sh 每次构建都调用）
geticon.swift              查系统实际解析出的 App 图标，用于验证图标是否真的生效
                           （**不参与构建**，排查「图标改了不生效」时手动编译）
check.sh                   改完随手跑：静态检查 + 只读冒烟（release.sh 会先调它）
build.sh                   构建与安装（通用二进制；--no-install 只构建）
release.sh                 打发布包：自检 + ditto 压缩 + 校验和 + 生成 Homebrew cask
uninstall.sh               卸载（会随 App 铺到运行目录，所以没源码也能用）
.github/workflows/release.yml  推 v* 标签自动发版
LICENSE                    Apache-2.0 原文（官方版本，逐字节一致）
NOTICE                     Apache-2.0 约定的署名文件
```
