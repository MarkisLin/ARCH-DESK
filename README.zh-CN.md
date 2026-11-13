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

左侧栏有两个工具。自检覆盖三十项左右，其中只有会话运行期间才成立的项，在桌面没跑时报 `SKIP`
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