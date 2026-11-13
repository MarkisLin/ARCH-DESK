# ARCH DESK

在 Android 平板上跑 Arch Linux ARM：合成器是 niri，桌面壳是 DankMaterialShell，应用直接用平板
自己的 GPU 绘制。不需要 root，不解锁 Bootloader，也不用虚拟机。

[English](README.md) | 简体中文

| | |
| --- | --- |
| 平台 | Android 8.0+，`arm64-v8a`，在 Android 16 上开发 |
| root | 不需要，guest 跑在 PRoot 里 |
| 桌面 | niri 26.04 + DankMaterialShell 2.1 |
| 图形 | Mesa zink → Vulkan（Venus）→ Mali-G925，以 dmabuf 呈现 |
| 磁盘 | 下载 830 MB – 1.76 GB，装完约 4.8 GB |
| 首次安装 | 正常网络下 10–20 分钟 |

这个仓库放三样东西：App 读取的 catalog、把官方 Arch Linux ARM 压缩包变成桌面的安装脚本、以及
给不想等首次配置的人准备的预构建运行时。App 和原生合成器的源码在应用仓库里。

## 为什么要做

平板上已经有买笔记本时想要的那台机器：八核、当代 GPU、比上网本更多的内存、3K 屏。它没有的是
把这些用在手机应用之外的地方的办法。一个应用占满屏幕，文件留在做它的那个应用里，没有 shell、
没有编译器、没有窗口管理器。

常见的绕法各要付一样东西：

| 绕法 | 代价 |
| --- | --- |
| SSH 到服务器 | 要有服务器和网络；平板自己的硬件在一边闲着 |
| Termux | 是终端不是桌面；没有窗口管理，没有加速的会话 |
| DeX / 桌面模式 | 还是 Android 应用，桌面需要的软件依然没有 |
| 云桌面 | 延迟、带宽、订阅，断网就没了 |
| 模拟器 | 模拟 CPU，比平板能跑的慢 |
| 虚拟机 | 零售设备不解锁 BL 就没有 |

这个项目选剩下那条：把 Linux on ARM 已经有的东西原生跑在平板自己的硬件上，不需要 root，不用
虚拟机。零件都在 —— Arch Linux ARM 几乎什么都有 aarch64 版本，GPU 能经 Vulkan 摸到。缺的是中间
那层管道，以及让管道在系统更新之后还能用的办法。

后半句是这个仓库长成这样的原因：一份配方加少量补丁，不是一份没人能维护的冻结镜像。

## 硬件

2026 年的中端平板有 8 个核、一块不弱的 GPU、8–16 GB 内存和 3K 屏，比多数人上网用的笔记本强。
Android 把这些硬件全用在了手机界面上。想在它上面要一个桌面，常见做法要么模拟 CPU，要么用 CPU
画图：

| | CPU | 渲染 |
| --- | --- | --- |
| PC 模拟器（QEMU/TCG） | x86 翻译成 ARM | 软件，SwiftShader |
| Termux + X11 | 原生 | `llvmpipe` |
| 远程桌面 | 远端 | 本地不渲染 |
| ARCH DESK | 原生 aarch64 | Mali GPU 上的 Vulkan |

开发机是联发科 MT8799（8 核、16 GB），guest 跑的是原生指令。PRoot 只在用户态改写与路径有关的
系统调用，别的什么都不做，所以 `gcc`、`pacman`、视频解码都是 SoC 的真实速度。

需要重建的只有图形。Android 不会给容器一个 DRM 节点，Mali 的内核驱动也没有按 Linux 桌面的方式
暴露出来，所以这条路绕到 Vulkan 上。

### Mali GPU 是怎么用上的

1. guest 里装一个讲 Venus 协议的 Vulkan ICD（`vulkan-virtio` 提供的
   `/usr/share/vulkan/icd.d/virtio_icd.json`，用 `VK_ICD_FILENAMES` 选中），Vulkan 调用被序列化
   成 Venus 协议。
2. 这个驱动连的是 App 私有目录里的 `files/venus/vtest.sock`，不涉及任何 `/dev` 节点。
3. APK 自带 `libvirgl_test_server.so`，从自己的 `nativeLibraryDir` 在 App 进程里启动。放在进程里
   是为了让它扛住 App 覆盖安装。
4. server 解码 Venus 命令后调用平板真实的 Vulkan 驱动，活儿落到 GPU 上。
5. 渲染结果以 dmabuf 文件描述符回传，guest 导入成 EGL image，不经过 CPU 内存。
6. Mesa 的 EGL 打过补丁，会选中 `zink` 并让 kopper 自建 `VkSwapchain`。帧以 dmabuf 进宿主合成器，
   再进 Android surface。

第 6 步决定桌面能不能用。没有这个补丁，Mesa 判定没有 DRM、没有 Wayland 缓冲路径，加载 `swrast`，
每帧经 `wl_shm` 拷一遍。3K 屏上的表现就是黑窗口加个位数帧率，GPU 全程闲着。

在 guest 里可以确认实际走的是哪条路：

```console
$ glmark2 -b build
GL_RENDERER: zink Vulkan 1.3(Virtio-GPU Venus (Mali-G925-Immortalis MC12))
```

这一行里出现 `llvmpipe` 或 `softpipe` 就说明补丁没生效，自检页对应的项是 `egl-patched`。

## 这个项目的目标

目标不是把 Linux 在平板上启动起来截个图。是让平板真的像它硬件上本来就是的那台 Linux 机器：
桌面能撑一个工作日，GPU 不闲着，触控和鼠标按人预期的方式工作，`pacman` 还能用，系统可以维护
而不是冻结在出厂状态。

由此定了下面几条验收标准，这个项目大部分工作都是因为其中某一条没过：

- 合成器跑在 GPU 上，用 renderer 字符串确认，不靠手感；
- 屏幕按原生 3008 × 1880 铺满，没有黑边，没有客户端标题栏；
- 手指点到哪，指针就在哪；外接鼠标推动同一个指针；
- 声音能放、麦克风能录，桌面壳的滑块改的是真实音量；
- 会话由 App 拉起，不需要终端；App 重装之后还能起来；
- guest 里有个检查，能区分"装坏了"和"能用"。

## 这个项目是怎么拼起来的

四层：

| 层 | 位置 | 干什么 |
| --- | --- | --- |
| guest 运行时 | `files/linuxfs` | Arch 系统本体：niri、桌面壳、Mesa，以及用户自己装的东西 |
| 会话脚本 | APK 资产，每次启动 stage 进运行时 | 入口、supervisor、音频/网络/蓝牙桥、自检与修复 |
| 配置脚本 | `archdesk-provision`、`packages.txt` | 把官方压缩包变成上面那个运行时，之后修漂移 |
| catalog | 这个仓库 | 告诉 App 下载什么、怎么校验 |

脚本每次启动都从 APK 重新 stage，不是就地改。运行时是一次性的：升级整个换掉，所以必须活下来的
东西只能放在 App 里。源码树里算数的那份是 `linuxdesk/tools/linuxfs/overlay`，Gradle 每次构建前
用它重新生成资产目录 —— 所以只改 assets 里的文件，看起来会没有效果。

一次会话的启动顺序：

1. App 解开或准备好运行时，在自己的进程里起 PulseAudio 和 Venus test server。
2. `startlxqtwayland` 设 guest 环境（ICD、音频 socket、会话 socket），重打 EGL 补丁和符号链接，
   首次启动时跑配置，把桌面 supervisor 脱离终端拉起，然后 `exec niri`。
3. supervisor 等 niri 的 socket，从文件名推出 `WAYLAND_DISPLAY` 和 `NIRI_SOCKET`，清掉 GL 变量，
   用原版 EGL 起桌面壳。壳掉了就重拉；壳把自己解包出来之后，补它的音频服务。
4. 两个小服务占住 NetworkManager 和 BlueZ 的总线名，用 Android 的状态回答。
5. App 里的合成器把 guest 的 surface 呈现到 Android surface 上。

## 这个项目是怎么开发的

每个子系统走的是同一个循环，因为这里猜错的代价很高：猜错一次就是一个构建、一次安装、一次会话
重启。

1. 先量再改。帧的问题靠数颜色和采样像素判断，不靠看截图。整屏 `64,64,64` 说明 surface 没画；
   顶栏有已知颜色；原来有水印的区域现在只剩一种颜色，就说明水印没了。
2. 找到错的那一环。曾经出现过所有进程都活着、layer 全注册了、日志一行错误没有，但屏上什么都
   没有。这个组合指向"客户端被推到了错的 GPU 通路"，不是桌面壳的问题。
3. 只改这一环，再量一次。
4. 留下一个检查，让下一个人能区分装坏了和能用。

代价大的错误记在 `docs/rendering.md` 和提交历史里，因为它们比成功更贵：

- 第一版 EGL 补丁改的是 `dri2_initialize_wayland_drm`，软件渲染根本走不到那个分支，等于没改。
- 有一次补丁明明打了却没效果，因为 `libEGL_mesa.so.0` 还指着没打补丁的文件。
- 把一个 `wl_output` 对象发给所有客户端是协议违规。niri 带着 `ContextLost` 死掉，整个会话跟着
  没了；每个客户端只能拿到自己连接上的那个 output 对象。
- 桌面壳 layer 都在、却什么都不画，因为会话级的 zink 变量把它推回了 Venus 通路。清掉环境变量、
  给它第二份 EGL，一步就好了。
- relative-pointer 绑定让合成器吞掉了绝对位移：事件都到了，指针不动。删掉位移路径上的一个条件
  就好了。
- 冻结的运行时镜像好发布、没法维护。换成官方压缩包加配置脚本。

## 安装

| 东西 | 链接 |
| --- | --- |
| APK（arm64） | [ARCHDESK-debug.apk](https://github.com/MarkisLin/ARCH-DESK/releases/download/app-2026.11.13/ARCHDESK-debug.apk) |
| 官方源 catalog（默认） | [`linuxfs-arch-official.json`](linuxfs-arch-official.json) |
| 预构建运行时 1.76 GB（可选） | [release `linuxfs-2026.11`](https://github.com/MarkisLin/ARCH-DESK/releases/tag/linuxfs-2026.11) |

APK 用测试证书签名、标了 debuggable，因为平板上跑的就是这一版。目前没有商店上架，也没有更新通道。

1. 装 APK，打开。
2. 按提示给通知、麦克风、定位权限。麦克风决定有没有 `DirectAudioMic`，定位决定 Wi-Fi 面板能不能
   显示详情。
3. 点「打开桌面」。App 会下载官方 Arch Linux ARM 压缩包、解开，首次启动时自动配置。
4. 如果开了"启动时进入桌面"，之后打开 App 就直接进桌面。

| | 官方源（默认） | 预构建 |
| --- | --- | --- |
| 下载 | 约 830 MB | 1.76 GB |
| 首次安装 | 10–20 分钟，取决于网速 | 2–4 分钟 |
| 能否立刻 `pacman -Syu` | 可以 | 首次升级之后可以 |
| 配好之后离线可用 | 可以 | 可以 |

需要约 6 GB 空闲空间。下载支持断点续传；catalog 里给了 sha256 时，App 在动已装的系统之前会先
校验大小和哈希。

左侧栏有三个工具：商店、配置、自检。自检覆盖三十项左右，其中只有会话运行期间才成立的项，在桌面没跑时报 `SKIP`
而不是失败。修复是幂等的：重新 stage 随包脚本、还原 EGL 补丁和符号链接、重写 `/etc/os-release`、
补回 `pactl` 包装、重打桌面的音频补丁、重启两个 D-Bus 服务。没有会话在跑时，它会用画中画把桌面
拉起来干完活再收起来。

## 桌面上有什么

- **niri** 管窗口。可滚动平铺适合平板：每个窗口占一条满高的列，左右滚动是触屏上本来就有的手势。
- **DankMaterialShell** 提供顶栏、Dock、控制中心和设置。它就是个普通 Wayland 客户端，壳崩了不会
  带走整个会话。
- **触控**把指针挪到手指的位置并在那里按下。不是触控板；之前那套触控板逻辑会让点击落在指针当时
  恰好在的地方。
- **外接鼠标**走指针捕获：App 拿到原始相对位移，把移动、按键、滚轮转发进 guest。两条输入最后都
  汇到合成器同一个指针上。
- **声音**来自跑在 App 里的 PulseAudio，sink 直接写进 `AudioTrack`，所以 guest 看到的是
  `DirectAudio`；麦克风是同一套路子，pipe source 由 App 的录音器喂数据，叫 `DirectAudioMic`。
- **网络和蓝牙面板**由两个小服务供数据：它们占住 `org.freedesktop.NetworkManager` 和
  `org.bluez` 的总线名，用 Android 的真实状态回答。只负责描述，不负责连接。

## 应用与更新

App 自带一份约九十个包的目录（`store.json`），分八类，每个包有一句中英双语说明。从商店安装时，
`pacman -S` 跑在一个 fake root 的 proot 里，包装进的就是桌面启动用的那份根文件系统；包写出
`.desktop` 之后，启动器里马上能看到。目录之外的软件，在终端里照常 `pacman` 装。

系统升级放在自检页：进页面时数一次 `pacman -Qu`，点更新就执行 `pacman -Syu`，输出实时显示在卡片里。
DMS 自己有个"软件更新"页，但它调的是 `pkexec`，要有真 setuid 和 polkit 才能跑——在这里是死路。

## 已验证的硬件

| 设备 | SoC / GPU | Android | 情况 |
| --- | --- | --- | --- |
| Redmi K Pad（`25079RPDCC`） | 联发科 MT8799 / Mali-G925-Immortalis MC12 | 16 | 日常使用：niri + 桌面壳、Chromium、VLC、终端、声音输入输出、鼠标和触控 |

别的设备没试过。可能在其它机器上不成立的假设有三个：Vulkan 驱动接受 Venus、GPU 能导出 dmabuf、
有 4 GB 以上空闲空间。没有可用 Vulkan ICD 的机器会掉回软件渲染。

## 设计取舍

- **用 PRoot，不用 chroot。** 零售设备没有 root，解 BL 要拿保修、Play Integrity 甚至相机去换。
  代价是没有 namespace、没有 `mount`、没有真 `/proc`、没有 `setuid`。
- **改 EGL 加载器，不重编 Mesa。** 两条指令的改动，加一个在 `pacman` 升级后补回去的包装脚本。
  在设备上为 aarch64 编 Mesa 又慢又容易在下一个版本上散架。
- **两套 EGL。** niri 用打过补丁、走 GPU 的那份；桌面壳在 llvmpipe 上用 `/opt/egl-orig` 里的原版，
  环境变量也要清干净，因为两边共用一个 Venus 客户端会一起段错误。
- **官方包加配置脚本，不做冻结镜像。** 冻结镜像好发布、难维护。用配置脚本能让 `pacman` 继续可用，
  用户可以自己装软件，系统也能继续吃到上游修复。
- **做桥，不移植 NetworkManager 和 BlueZ。** 这两个都要 netlink、D-Bus 策略和内核模块，PRoot 给
  不了。用同样的总线名汇报 Android 的状态，已经够面板显示。

## 已知不足

- **没有沙箱。** PRoot 不创建 namespace，`bwrap`、Chromium 的 zygote 沙箱、QtWebEngine 的沙箱都
  无法工作。运行时带了一个 `bwrap` 垫片，启动包装器会传 `--no-sandbox`；安全边界是 Android 的
  应用沙箱。
- **GPU 是间接的。** 没有 `/dev/dri` 渲染节点，需要 GBM 或探测 DRM 的程序会失败。所有渲染走
  Vulkan。
- **没有 systemd。** 服务就是被会话看管的脚本，没有 timer、没有 socket 激活、没有依赖排序。
- **后台受 Android 管。** 内存紧张时会话可能被杀；后台 UID 没有网络，所以安装过程必须挂着前台
  通知。
- **面板只能看。** 能显示当前网络和已配对蓝牙设备，不能扫描新网络、不能配对新设备。
- **单 sink、单 source。** 没有按应用分流，没有 HDMI，没有多麦克风。
- **嵌套呈现。** guest 渲染到一个 surface，Android 再合成一次，每帧有一点固定开销，也没有 HDR。
- **EGL 补丁要养。** 它绑在某个 Mesa 大版本的加载器布局上。跨度大的 `pacman -Syu` 会让它失效，
  自检会发现、修复工具会把文件补回去，但补丁本身迟早要重新推导。
- **只测过一个 SoC。** 全部开发对着 Mali 做，Adreno 没试过。
- **LibreOffice 还起不来**，退出时打印 `ERROR: /proc not mounted`。

## 后续

方向是不再维护一份冻结镜像，而是维护一份配方。配方可以重跑、可以对比、可以修；镜像只能重新下载。

- 不依赖前台也能完成配置。
- 把 `dms`、quickshell 和补丁做成签名仓库里的 `pacman` 包，让桌面跟着系统一起更新。
- 公开 App 源码，发一个用正式证书签名的版本。
- 把硬件面板补完，或者干脆把做不到的部分藏起来，而不是显示空列表。
- 修掉 LibreOffice 的 `/proc` 问题和 niri 每秒重建 output 的抖动。
- 更远一点：guest 里有一个真正的 init、零拷贝呈现、外接显示器和键盘、以及在平台允许时走容器或
  虚拟机。

## 仓库结构

```
.
├── README.md                   英文
├── README.zh-CN.md             本文件
├── linuxfs-arch-official.json  默认 catalog：官方包 + 配置脚本
├── linuxfs-arch.json           备用 catalog：预构建运行时
├── docs/
│   ├── rendering.md            渲染管线、kopper、怎么确认真的在用 GPU
│   ├── runtime-layout.md       文件在哪、会话启动顺序
│   └── publishing.md           打包、发版、回滚
└── CHANGELOG.md
```

catalog 字段：

| 字段 | 含义 |
| --- | --- |
| `version` | `YYYY.MM`，跟已装版本比对 |
| `kind` | `official`（官方包 + 配置）或 `rootfs`（预构建） |
| `format` | `tar.gz` 或 `tar.zst` |
| `url` | 直接下载地址 |
| `sha256` | `official` 可省，`rootfs` 必填 |
| `size` | 字节数 |

## 出处

这个项目是从 [DroidDeck](https://github.com/Droid-Deck/DroidDeck) 0.6.9 fork 出来的。DroidDeck 做的是
在 Android 上跑 Steam Gaming Mode，渲染思路来自那里：把 Wayland 合成器放进 App 里、把 guest 的
surface 呈现到 Android surface；用 Venus/virgl 桥把 Vulkan 经 socket 交给厂商驱动；以及
`files/linuxfs` 下那套 proot 会话布局。ARCH DESK 保留了包名和 `droiddeck-*` 脚本名，这样已经装好的
用户可以原地升级。

为了从游戏壳改成桌面，改动了这些地方：会话从 gamescope 换成 niri + DankMaterialShell；EGL 加载器
打了 kopper 补丁，桌面壳改用另一份原版 EGL；触控从触控板改成绝对指针；重写了指针捕获，让鼠标真的
能推动 guest 里的指针；网络和蓝牙面板改成由 Android 供数据；运行时改成从官方包安装并跑配置脚本；
App 里加了自检和修复。

其余都是别人的东西：Arch Linux ARM、niri、DankMaterialShell 与 quickshell、Mesa、virglrenderer 与
Venus 协议，以及它们依赖的包。

## 许可

运行时里的包各自遵循上游许可证。本仓库的脚本、catalog 和文档打算用 MIT，`LICENSE` 文件还没放进来，
所以这句话目前只是意图，不是授权。