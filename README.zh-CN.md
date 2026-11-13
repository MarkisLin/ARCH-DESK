# ARCH DESK

**在 Android 平板上跑一个真正的 Arch Linux ARM 桌面 —— niri + DankMaterialShell。
不需要 root，不需要解锁 Bootloader，不是虚拟机。**

[English](README.md) | 简体中文

---

ARCH DESK 把一台普通 Android 平板变成 Linux 工作站。用户空间是货真价实的 Arch Linux ARM
aarch64：有 `pacman`、有滚动更新、有完整的系统库。桌面同样是真正的 Wayland 会话：niri 做合成器，
DankMaterialShell（DMS）做桌面外壳，应用直接吃平板自己的 GPU。

没有模拟，也没有串流。唯一"属于 Android"的部分是两界之间的传输层：一个把 guest 会话呈现到
Android `Surface` 上的 Wayland 合成器、一条把 Vulkan 命令交给厂商驱动的桥，以及几座让桌面能看见
Android 手里硬件（音频、网络、蓝牙、输入）的小桥。

本仓库是这个用户空间的**分发通道**：App 读取的 catalog、把官方 Arch Linux ARM 压缩包变成桌面的
provision 配方，以及给"不想等首次配置"的人准备的预构建运行时。

| | |
| --- | --- |
| 平台 | Android 8.0+（`arm64-v8a`），在 Android 16 上验证 |
| root | **不需要** —— guest 跑在 PRoot 里 |
| 桌面 | niri 26.04 + DankMaterialShell 2.1 |
| 图形 | Mesa `zink` → Vulkan（Venus）→ Mali-G925，dmabuf 呈现 |
| 体积 | 解压约 4.8 GB，下载 830 MB – 1.76 GB |
| 首次安装 | 正常网络下 10–20 分钟 |

---

## 目录

- [为什么做这个](#为什么做这个)
- [它是怎么工作的](#它是怎么工作的)
- [这个仓库里有什么](#这个仓库里有什么)
- [安装](#安装)
- [已验证的硬件](#已验证的硬件)
- [设计取舍](#设计取舍)
- [已知不足](#已知不足)
- [路线图](#路线图)
- [仓库结构](#仓库结构)
- [许可](#许可)

---

## 为什么做这个

今天的平板比大多数人上网用的笔记本更强：八核、新一代 GPU、8–16 GB 内存、3K 屏、续航一整天。
Android 把这些算力全给了手机界面。现成的几条退路都不够好：

| 方案 | 给你什么 | 缺什么 |
| --- | --- | --- |
| SSH / VNC 连远程机器 | 一个真桌面 | 依赖网络、有延迟、用不上本地 GPU、断网即死 |
| Termux + X11 | 一个 shell、少量 GUI | 没有合成器、软件渲染、几乎没有窗口管理 |
| 厂商"桌面模式"（DeX 之类） | 顺滑的 Android 窗口 | 闭源、不是 Linux、没有 `pacman` |
| 云游戏 / 云 Linux | 省事 | 不是你的机器、不离线、不免费 |

ARCH DESK 的赌注很简单：**平板本身就可以是那台电脑** —— 前提是能在 Android 旁边跑一个带 GPU
加速、能共享硬件的真 Wayland 会话。有 root 这件事很容易；但大多数人手上的设备没有 root，所以
真正有工程价值的部分是"没有 root 也做到"。

## 它是怎么工作的

### 两半

```
┌─────────────────────────── Android App（Kotlin/Compose）───────────────────────────┐
│  前端（Compose）          会话服务                    原生侧（C / NDK）             │
│  ├ 安装 / 自检 / 修复      ├ PRoot 监管                ├ waylandcomp（合成器）        │
│  ├ 设置 / 画中画           ├ Venus vtest server  ◄──────── wl socket ──────────┐    │
│  └ 启动会话                ├ PulseAudio          ◄──────── pulse socket ───┐   │    │
│                            └ 输入 / 指针捕获                              │   │    │
│                                     │                                     │   │    │
│                                     ▼                                     │   │    │
│                           Android Surface ──► SurfaceFlinger ──► 屏幕    │   │    │
└───────────────────────────────────────────────────────────────────────────┼───┼────┘
                                                                            │   │
┌──────────────────────────── Arch Linux ARM（PRoot）───────────────────────┼───┼────┐
│  niri（Wayland 合成器）◄── wayland client ─────────────────────────────────┘   │    │
│  ├─ DankMaterialShell（dms + quickshell/Qt6）                                  │    │
│  ├─ 应用（Chromium、VLC、LibreOffice、终端……）◄── audio ──────────────────────┘    │
│  └─ pacman、无 systemd 的服务脚本                                                  │
└────────────────────────────────────────────────────────────────────────────────────┘
```

guest 以为自己连的是一个普通 Wayland 合成器、一个普通 PulseAudio、一套普通 D-Bus 服务。
它确实连的是，只不过这些东西住在 Android 进程里。

### 渲染链路

guest 里既没有 DRM 设备，也没有 `/dev/dri` 渲染节点；Mali 的内核驱动也没有按 Linux 桌面的方式暴露
给用户态。所以整条链路围绕 Vulkan 重建：

```
GL 应用 ──► Mesa zink ──► Vulkan ──► Venus（virtio-gpu）──► vtest socket
                                                              │
                   Android：libvirgl_render_server ──► Mali-G925 ──► dmabuf
                                                              │
                        waylandcomp 取走 dmabuf ──► Android Surface ──► 屏幕
```

其中两个细节比其它所有细节都重要：

**kopper。** Mesa 在 Wayland 上的 EGL 通常需要 DRM 渲染节点或 `wl_drm` 来分配缓冲。这两样我们都
没有，于是上游 Mesa 判定驱动不可用、退回 `swrast`，整个会话变成把每一帧经 `wl_shm` 拷一遍 ——
在这台机器上的表现就是黑帧和个位数帧率。解决办法是让 Mesa 选中 `zink`，再由 **kopper** 自建
`VkSwapchain`，缓冲以 dmabuf 形式流转、完全不碰 CPU。落地方式是给 `libEGL_mesa.so.0.0.0` 打两条
指令的补丁，外加一个符号链接修正；随机时分发、被 `pacman` 覆盖后由修复工具重新打上。

**两套 EGL 人格。** niri 需要打过补丁（GPU）的 EGL。DMS 是 Qt/quickshell 应用，llvmpipe 跑得很
正常；让它和 niri 共用同一个 Venus 客户端会让两边一起段错误。所以运行时在 `/opt/egl-orig` 保留
一份原版，由监督脚本在**清洗过的环境**里用它启动 DMS —— 必须 `env -u` 掉
`MESA_LOADER_DRIVER_OVERRIDE`、`GALLIUM_DRIVER`、`VK_ICD_FILENAMES` 这些变量，光它们就足以把 Qt
拽回 Venus。

### 输入

这里的触摸不是触控板。手指落在哪儿，指针就到哪儿并在那儿按下 —— 这是平板上的直觉行为，也是 3K 屏
上唯一不会"看不见光标"的行为。外接鼠标是另一条路：App 申请**指针捕获**，拿到原始相对位移，再作为
相对移动 + 按键 + 滚轮送进 guest。两条路最终汇进同一个合成器指针。

### 音频

PulseAudio 跑在 Android App 进程里（`libpulseaudio.so`），其中一个 sink 模块直接写进 `AudioTrack`。
guest 通过 Unix socket 看到一个正常的 PulseAudio 服务；sink 名为 `DirectAudio`，麦克风名为
`DirectAudioMic`（pipe source，由 App 的录音器喂数据）。Android 音量键、权限、guest 混音器三者保持
一致。

### 系统服务

DMS 通过 D-Bus 跟系统打交道：网络面板找 `org.freedesktop.NetworkManager`，蓝牙找 `org.bluez`。
PRoot 用户空间里没有这两个服务。运行时没有去移植它们，而是装了两个小替身（`dd-nmmock`、
`dd-bluez`）占住总线名，用 Android 真实状态回答 —— 当前 SSID、地址、网关、信号、适配器、已配对
设备。这是"桥"而不是"模拟器"：它只汇报，不负责连接。

### Provisioning

默认安装路径下载**官方** `ArchLinuxARM-aarch64-latest.tar.gz`，解开，首次启动跑
`archdesk-provision`。这个脚本修掉官方 ARM 包在容器里必然出问题的地方（`nsswitch.conf` 里的
`resolve` 让 DNS 全线失败、`/etc/resolv.conf` 是悬空符号链接、`pacman.conf` 指向一个不存在的仓库），
装上桌面需要的 34 个顶层包（实际解析出约 400 个包），塞进没有 Arch 包的部分（`dms`、打过补丁的
EGL、几座桥），最后落一个完成标记。

这样做是为了可维护性：guest 是一套滚动的 Arch 系统，`pacman -Syu` 一直可用，用户可以自己装软件，
而不是被冻在一张手工镜像里。

## 这个仓库里有什么

| 文件 | 用途 |
| --- | --- |
| [`linuxfs-arch-official.json`](linuxfs-arch-official.json) | 默认 catalog：官方 Arch Linux ARM 包 + provision |
| [`linuxfs-arch.json`](linuxfs-arch.json) | 备用 catalog：1.76 GB 预构建运行时，开箱即用 |
| [`docs/rendering.md`](docs/rendering.md) | 为什么需要 kopper、为什么两套 EGL、怎么证明真的在跑 GPU |
| [`docs/runtime-layout.md`](docs/runtime-layout.md) | 目录导览，以及一次会话的启动顺序 |
| [`docs/publishing.md`](docs/publishing.md) | 打包、发版、更新 catalog、回滚 |
| [`CHANGELOG.md`](CHANGELOG.md) | 变更记录 |

### catalog 格式

App 读 `BuildConfig.LINUXFS_CATALOG`，期望这样的 JSON：

```json
{
  "version": "2026.11-stock",
  "kind": "official",
  "format": "tar.gz",
  "url": "https://mirrors.aliyun.com/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz",
  "size": 829367415
}
```

| 字段 | 含义 |
| --- | --- |
| `version` | 人类可读版本，约定 `YYYY.MM`；App 用它判断"装的是不是这个版本" |
| `kind` | `official`（官方包 + provision）或 `rootfs`（预构建镜像） |
| `format` | `tar.gz` 或 `tar.zst`，同时决定解压器 |
| `url` | 可匿名下载的直链 |
| `sha256` | `official` 可省略，`rootfs` 必填 |
| `size` | 字节数，用于进度与磁盘空间判断 |

### Release 资产

- `linuxfs-arch-2026.11.tar.zst` —— 1.76 GB 预构建运行时（解压 4.75 GB），zstd 压缩。
- provision 相关脚本随 APK 分发、不放在这里，这样它们永远和 App 版本匹配。

## 安装

1. 装上 ARCH DESK 的 APK（arm64）。
2. 按提示给通知权限、"安装未知应用"；被问到时给麦克风与定位权限 —— 前者决定有没有 `DirectAudioMic`，
   后者决定 Wi-Fi 详情能不能显示。
3. 打开 App，点**打开桌面**。运行时会下载、校验、解包并自动 provision。
4. 桌面出现。之后如果开了"启动时进入桌面"，下次打开就直接进。

| | 官方源（默认） | 预构建 |
| --- | --- | --- |
| 下载 | 约 830 MB | 1.76 GB |
| 首次安装 | 10–20 分钟（取决于网速） | 2–4 分钟 |
| 能否直接 `pacman` 滚动 | 可以，立刻 | 可以，首次 `pacman -Syu` 之后 |
| 配好之后离线可用 | 是 | 是 |

需要约 6 GB 空闲空间。下载支持断点续传；在发布 `sha256` 时，App 会在动到已装系统之前先校验大小与哈希。

### 自检与修复

都在 App 左侧栏。自检约三十项：二进制、随包脚本、EGL 补丁哈希、Venus socket、niri/DMS/quickshell
的 socket、PulseAudio 与两个节点、两个 D-Bus 桥、以及 guest 里那份网络快照。只在桌面运行期间才
成立的项，桌面没跑时会报 `SKIP` 而不是 `FAIL`，所以在闲置的平板上做检查仍然有意义。

修复是幂等的：重新 stage 资产、还原 EGL 补丁与符号链接、重写 `/etc/os-release`、补回 `pactl`
包装、重打 DMS 音频补丁、重启两座桥。如果当时没有会话在跑，它会用**画中画**把桌面拉起来干完活，
再收起来。

## 已验证的硬件

| 设备 | SoC / GPU | Android | 结果 |
| --- | --- | --- | --- |
| Redmi K Pad（`25079RPDCC`） | 联发科 MT8799 / Mali-G925-Immortalis MC12 | 16 | 日常可用：niri + DMS、Chromium、VLC、终端、音频输入输出、鼠标 + 触控 |

其它设备没有测过。有风险的假设是三条：Vulkan 驱动能接受 Venus；GPU 能导出 dmabuf；有 4 GB 以上
空闲空间。没有可用 Vulkan ICD 的设备会退回软件渲染，慢到不可用。

## 设计取舍

**用 PRoot，不用 chroot。** 零售设备拿不到 root，解 BL 要付出保修、Play Integrity，有时还有相机。
PRoot 在用户态拦截路径解析类系统调用，不需要任何特权。代价是真实的：没有 namespace、没有 `mount`、
没有真 `/proc`、没有 `setuid`。

**用 niri，不用浮动窗口合成器。** 平板是一块没有键盘、没有鼠标的矩形。可滚动平铺给每个窗口一条
可预测的满高列，手势天然映射成横向滚动，也没有需要用手指去够的窗口边框按钮。

**用 DankMaterialShell，不自己写壳。** quickshell 直接给出一套成熟的顶栏、Dock、控制中心与设置界面，
QML 迭代很快。附带好处是壳就是个普通 Wayland 客户端，壳崩了不会带走整个会话。

**改 EGL，不改 Mesa。** 在设备上为 aarch64 重编 Mesa 又慢又脆；给 EGL 加载器打两条指令补丁、再用
一个包装脚本在 `pacman` 升级后补回去，运行时零成本。

**做桥，不做服务。** 在容器里塞一个完整 NetworkManager 或 BlueZ，意味着 netlink、D-Bus 策略、内核
模块，这些 PRoot 给不了。用同样的总线名汇报 Android 的状态，能拿到 95% 的可见价值，只花 5% 的成本
—— 而且它对"做不到什么"是诚实的：它不负责连网，只描述 Android 已经连上的那个网。

**官方包 + provision，不做冻结镜像。** 冻结镜像好发、难养。provision 让 `pacman` 保持有用，让用户
能自己装软件，也让版本之间的差异变小。

## 已知不足

这些不是待办清单，而是当前设计的形状。

- **没有沙箱。** PRoot 不提供 namespace，所以 `bwrap`、Chromium 的 zygote 沙箱、QtWebEngine 的沙箱
  都无法工作。运行时带了一个 `bwrap` 兼容垫片，启动包装器会传 `--no-sandbox`；真正的安全边界是
  Android 的应用沙箱（UID + SELinux）。Electron 系、Chromium 系、任何自带 `chrome-sandbox` 的程序
  都需要那个开关。
- **GPU 是间接的。** 没有 DRM 渲染节点。探测 `/dev/dri` 或依赖 GBM 的程序会找不到。所有渲染都走
  Vulkan/kopper，够快，但不等于原生 Linux GPU 栈。
- **没有 `systemd`。** 服务就是被会话监管的普通脚本。没有 timer、没有 socket 激活、没有依赖排序；
  任何假设 `systemctl` 存在的东西都用不了。
- **后台执行由 Android 决定。** 内存吃紧时系统可能杀掉会话；后台 UID 的网络被限制 —— 所以下载必须
  让 App 在前台，这也是安装器一直挂着前台通知的原因。
- **硬件面板不完整。** DMS 能显示当前网络与已配对蓝牙设备，但不能扫描新 Wi-Fi、不能配对新设备：
  这些操作在 Android API 后面，桥还没去调。
- **单 sink、单 source。** 音频走默认输出；没有按应用分流，没有 HDMI，也没有多麦克风建模。
- **嵌套呈现。** guest 合成器渲染到一个 `Surface`，再由 Android 合成一次。没有直接扫描输出，所以
  每帧有一笔固定小开销，也没有 HDR。
- **补丁要养。** EGL 补丁绑在某个 Mesa 大版本的 `libEGL_mesa` 布局上。一次跨度大的 `pacman -Syu`
  可能让它失效；自检会发现、修复工具会补回，但补丁本身迟早要重新推导。
- **只测过一个 SoC。** 全部开发都对着 Mali + Venus 做。Adreno 的 Vulkan 故事不一样，未测。

## 路线图

**近期 —— 让日常使用变得无聊**

- 不依赖前台也能完成 provision（前台服务 + 可续传下载）。
- 用真正的会话生命周期取代"启动时进桌面"的猜测（配置变更不丢、被低内存杀掉后能恢复）。
- 把硬件面板做得诚实：能报的报，不支持的置灰，而不是显示一个空列表。
- 修掉 niri 每秒重建 output 的抖动，以及 LibreOffice 因 `/proc` 起不来的问题。

**中期 —— 让陌生人也能装上**

- 把 `dms`、quickshell 和补丁做成真正的 `pacman` 包，放在签名仓库里，让 `pacman -Syu` 也能更新桌面。
- 公开 App 源码、签名产物与可复现打包流程；再验证第二台设备。
- 官方源与预构建之间可迁移，并支持回滚到上一个 rootfs。
- 结构化桥：在宿主侧调 `WifiManager`/`BluetoothAdapter`，给 guest 一个小的强类型接口，而不是长期
  维护 D-Bus 替身。

**远期 —— 这个东西的形态**

- guest 里有一个真正的 init（runit/s6 风格），服务是声明出来的，不是手工看护的。
- 零拷贝呈现：dmabuf 直接进 Android 合成器，帧节奏跟着屏幕 vsync。
- 外接显示器、硬件键盘、触控板作为一等输入。
- 在平台允许的地方走真正的隔离（容器或虚拟机），PRoot 作为通用回退。

## 仓库结构

```
.
├── README.md                   英文版
├── README.zh-CN.md             本文件
├── linuxfs-arch-official.json  默认 catalog（官方包 + provision）
├── linuxfs-arch.json           备用 catalog（预构建运行时）
├── docs/
│   ├── rendering.md            渲染管线、kopper、如何验证 GPU
│   ├── runtime-layout.md       文件在哪、会话启动顺序
│   └── publishing.md           打包、发版、回滚
└── CHANGELOG.md
```

本仓库只承载产物与清单，不放应用源码。App、原生合成器与打包脚本在应用仓库（`linuxdesk/`）里，
包括 `tools/package-linuxfs.sh` 与 `tools/provision/`。

## 许可

运行时内是 Arch Linux ARM 及其上游项目的软件，各包遵循各自许可证。本仓库的脚本、清单与文档计划
以 MIT 发布 —— 正式的 `LICENSE` 文件还没落地，所以这段文字代表意图，还不是法律文本。