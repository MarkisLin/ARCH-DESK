# LinuxDesk Components

LinuxDesk 在 Android 平板上跑 Arch Linux ARM 桌面所需的**预构建运行时**（rootfs）与 **catalog 清单**。

这个仓库只放"大块头、变化慢、需要单独下载"的东西：一个定制好的 Arch Linux ARM 根文件系统。
App（`com.dsh.linuxdesk`）本身不携带 rootfs，首次启动时按 `linuxfs-arch.json` 下载一次，
校验大小与 SHA-256 后解压到 `files/linuxfs`，之后完全离线运行。

- 不需要 root，不需要解锁 Bootloader
- 桌面是真正的 Wayland 合成器（niri）+ 完整 Arch 用户空间，不是套壳终端
- 渲染走 GPU：Mesa EGL（kopper 补丁）+ Venus/virgl 把 Vulkan 转发到 Android 的 Mali 驱动

---

## 当前组件

| 组件 | 版本 | 压缩后 | 解压后 | 内容 |
| --- | --- | --- | --- | --- |
| `linuxfs-arch` | 2026.11 | 1.76 GB | 4.75 GB | 定制 Arch Linux ARM aarch64 rootfs：niri + DankMaterialShell 桌面、Mesa kopper 补丁、Venus 渲染通路，以及全部桥接脚本 |

下载地址与校验值都在 [`linuxfs-arch.json`](linuxfs-arch.json) 里，Release 资产名为
`linuxfs-arch-2026.11.tar.zst`（zstd 压缩的 tar，`tar --zstd -xf` 即可展开）。

---

## 这个运行时里有什么

### 桌面

- **niri 26.04** — 滚动平铺式 Wayland 合成器，平板手势与触控的落点就是指针落点
- **DankMaterialShell（DMS）** — `dms`（Go 二进制）+ `qs`（quickshell/Qt6）组成的顶栏、Dock、控制中心、设置面板
- **会话入口** — `/usr/bin/startlxqtwayland`（名字是历史遗留）：准备 GPU 环境、修补 Mesa EGL、拉起 DMS 监督进程，最后 `exec niri`

### 图形栈

| 层 | 实现 | 说明 |
| --- | --- | --- |
| Vulkan | `libvulkan_virtio.so` + Venus | guest 侧把 Vulkan 命令流交给 Android 侧的 `libvirgl_test_server.so`，最终落到 Mali-G925 |
| OpenGL | Mesa `zink` → Vulkan | 没有原生 GL 驱动，GL 全部经 zink 走 Vulkan |
| EGL 呈现 | **kopper 补丁的 `libEGL_mesa.so.0.0.0`** | 让 zink 自建 VkSwapchain 走 dmabuf，绕开旧路径的 `wl_shm` 拷贝（那是黑屏与掉帧的根源） |
| 原版 EGL | `libEGL_mesa.so.0.0.0.orig` + `/opt/egl-orig/` | DMS 用原版（llvmpipe）启动，避免和 niri 抢同一个 Venus 客户端 |

kopper 补丁版 md5：`474a1a62a4faeb80f208d97329f7ce75`。

### 桥接脚本（`/usr/local/bin`）

| 脚本 | 作用 |
| --- | --- |
| `droiddeck-dms-supervisor` | 等 niri 的 socket → 用干净环境（`env -u` 掉 zink/Venus 变量）拉起 `dms run` → quickshell 掉线就重拉 → 给 DMS 打音频补丁 |
| `dd-nmmock` / `dd-nmmockd` | 用 python3 + `ctypes` 直接调 libdbus，冒充 `org.freedesktop.NetworkManager`，把手机当前的 Wi-Fi（SSID/IP/网关/信号）喂给 DMS |
| `dd-bluez` | 冒充 `org.bluez`，把手机蓝牙适配器与已配对设备喂给 DMS |
| `pactl` | 包装成 `LC_ALL=C /usr/bin/pactl`，否则中文 locale 会让 DMS 的正则匹配不到 sink |
| `droiddeck-selfcheck` | 27 项运行时自检，逐条 `OK`/`FAIL`，末行 `SUMMARY failed=N` |
| `droiddeck-repair` | 配套修复：把被 pacman、误删、半途而废的安装弄丢的东西放回去，末行 `SUMMARY fixed=N` |

音频由 App 侧的 PulseAudio 提供服务（socket 在 `files/pulseaudio/PS0`），guest 里出现两个节点：
`DirectAudio`（外放）与 `DirectAudioMic`（麦克风）。

### 明确不包含

`/root`、`/home`、`/proc`、`/sys`、`/dev`、`/run`、`/tmp`、`/var/cache/pacman/pkg`、`/var/log`，
以及 `/data`（Android 侧路径，打包时会递归，必须排除）。

---

## catalog 格式

App 通过 `BuildConfig.LINUXFS_CATALOG` 读这个 JSON（默认指向本仓库 `main` 分支的 raw 地址）：

```json
{
  "version": "2026.11",
  "url": "https://github.com/MarkisLin/linuxdesk-components/releases/download/linuxfs-2026.11/linuxfs-arch-2026.11.tar.zst",
  "sha256": "cbf8626df287368796ab7f0b3c90a5ef4ac7a78ce44f4d32f594082f0d2d5d1b",
  "size": 1759019097
}
```

| 字段 | 说明 |
| --- | --- |
| `version` | 人类可读版本，约定 `YYYY.MM`；App 用它判断"装的是不是这个版本" |
| `url` | 直链，必须能匿名下载（Release 资产即可） |
| `sha256` | 压缩包（`.tar.zst`）的哈希，下载后校验，不匹配则放弃 |
| `size` | 字节数，用于显示进度与提前判断磁盘空间 |

App 侧流程：`GET catalog` → 比对本地已装版本 → 下载到 `files/` → 校验 `size`/`sha256` → 解压到 `files/linuxfs` → 跑 `droiddeck-selfcheck`。

---

## 开发与发布

### 重新打包 rootfs

打包脚本在 App 仓库的 `tools/package-linuxfs.sh`：

```bash
tools/package-linuxfs.sh \
  --root /path/to/arch-rootfs \
  --version 2026.12 \
  --out dist/ \
  --base-url https://github.com/MarkisLin/linuxdesk-components/releases/download/linuxfs-2026.12
```

它会自动剔除上节列出的目录，用 `zstd -6 -T0` 压缩，并输出 `linuxfs-arch-<version>.tar.zst` 与
`linuxfs-arch.json`（含新算出的 `sha256` 与 `size`）。

### 发一个版本

1. 打包（上一步），确认 `tar --zstd -tf` 能列出内容、`zstd -t` 通过。
2. 建 tag `linuxfs-<version>` 与同名 Release，把 `.tar.zst` 传上去。
3. 把新的 `linuxfs-arch.json` 覆盖到本仓库根目录并提交——**App 只认这个文件**。
4. 老的 Release 保留不删：已经装好的用户不需要重新下载。

`upload.sh` 是把上面几步串起来的脚本（建仓库 / 发 Release / 传资产 / 回写 catalog），

### 版本约定

- tag：`linuxfs-YYYY.MM`（如 `linuxfs-2026.11`）
- catalog 永远在 `main` 根目录，文件名固定 `linuxfs-arch.json`
- 同一个版本号不重复发布；要改内容就升版本号

---

## 排障

用户侧只有两个入口，都在 App 左侧栏的 **自检** 页：

- **运行自检** — 27 项检查，覆盖二进制、随包脚本、EGL 补丁哈希、Venus socket、niri/DMS/quickshell
  socket、PulseAudio 及其两个节点、两个 D-Bus 服务、以及 guest 里那份手机网络状态。
- **修复** — 重新 stage 资产、还原 EGL 与符号链接、重写 `/etc/os-release`、补回 `pactl` 包装、
  重打 DMS 音频补丁、重启两个 D-Bus 服务。桌面没在跑时它会以**画中画**方式拉起桌面再修，
  不打断当前页面。修复是幂等的，第二次跑会得到 `SUMMARY fixed=0`。

日志（在 App 私有目录里，`run-as` 或文件管理器可读）：

| 文件 | 内容 |
| --- | --- |
| `files/logs/tools/selfcheck.log` | 最近一次自检的逐条结果 |
| `files/logs/tools/repair.log` | 最近一次修复的逐条结果 |
| `files/logs/<session>/desktop.log` | 桌面会话的启动过程与退出码 |

### 常见现象

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 桌面能进但顶栏显示"未找到输出设备" | DMS 没读到 PulseAudio 的 sink | 自检看 `audio-sink`；点"修复"重打音频补丁 |
| Wi-Fi 页空白 | `dd-nmmock` 没在 system bus 上占名 | 自检看 `nm-bus`；重新打开桌面或点"修复" |
| 蓝牙页空白 | `dd-bluez` 同上 | 自检看 `bt-bus` |
| 桌面黑屏 / 帧不动 | EGL 被换回原版，zink 退回 `wl_shm` | 自检看 `egl-patched` 的 md5，或点"修复" |
| 桌面起不来，`desktop.log` 里 `LXQt ended (139)` | Venus 的 vtest server 没起来（渲染通路断了） | 自检看 `venus-socket`，重启 App |
| 中文界面下音量显示"静音"且不可调 | 少了 `pactl` 包装，DMS 正则匹配不到 | 自检看 `pactl-wrapper` |

---

## 文档

| 文档 | 内容 |
| --- | --- |
| [`docs/rendering.md`](docs/rendering.md) | 渲染通路：为什么需要 kopper 补丁、为什么 DMS 用原版 EGL、如何确认真的跑在 GPU 上 |
| [`docs/runtime-layout.md`](docs/runtime-layout.md) | 目录导览：关键文件在哪、运行时产物在哪、一次会话的启动顺序 |
| [`docs/publishing.md`](docs/publishing.md) | 发布流程：打包、发 Release、更新 catalog、回滚、检查清单 |
| [`CHANGELOG.md`](CHANGELOG.md) | 版本变更记录 |

## 相关仓库

- App 仓库：`linuxdesk/`（Kotlin + Jetpack Compose + NDK 合成器）
- 打包脚本：`linuxdesk/tools/package-linuxfs.sh`
- 运行时细节：`linuxdesk/docs/development/arch-desktop-runtime.md`

本仓库只承载产物与清单，不放源码；改动请走 App 仓库。

## 许可

rootfs 内的软件各自遵循其上游许可证（Arch Linux ARM 及其包）。本仓库的脚本与清单部分待定，
在正式开源前会补充明确的 LICENSE 文件。