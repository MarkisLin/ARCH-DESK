# LinuxDesk Components

LinuxDesk（`com.dsh.linuxdesk`）在 Android 平板上运行 Arch Linux ARM 桌面所需的**预构建运行时组件**。

App 只在首次初始化时下载一次，之后完全离线运行。

## 当前组件

| 组件 | 版本 | 大小 | 解压后 | 说明 |
| --- | --- | --- | --- | --- |
| `linuxfs-arch` | 2026.11 | 1.76 GB | 4.75 GB | 定制 Arch Linux ARM rootfs：niri + DMS 桌面、Mesa kopper 补丁、Venus/virgl 渲染通路、dd-nmmock / dd-bluez / droiddeck-dms-supervisor / pactl 包装等桥接脚本 |

## 目录结构（catalog）

`linuxfs-arch.json` 是给 App 读的 catalog，App 通过 `BuildConfig.LINUXFS_CATALOG` 指向本文件的 raw 地址：

```json
{
  "version": "2026.11",
  "url": "https://github.com/<owner>/linuxdesk-components/releases/download/linuxfs-2026.11/linuxfs-arch-2026.11.tar.zst",
  "sha256": "cbf8626df287368796ab7f0b3c90a5ef4ac7a78ce44f4d32f594082f0d2d5d1b",
  "size": 1759019097
}
```

App 侧校验流程：下载 → 比对 `size` 与 `sha256` → 解压到 `files/linuxfs` → 执行 `/usr/local/bin/droiddeck-selfcheck` 自检。

## rootfs 里包含什么

- **桌面**：niri 26.04（Wayland 合成器）、DankMaterialShell（`dms` Go 二进制 + `qs`/quickshell）、labwc 会话入口 `/usr/bin/startlxqtwayland`
- **渲染**：Mesa EGL（kopper 补丁版，md5 `474a1a62a4faeb80f208d97329f7ce75`）、原版 EGL 备份 `/usr/lib/libEGL_mesa.so.0.0.0.orig`、Venus ICD `/usr/share/vulkan/icd.d/virtio_icd.json`
- **桥接脚本**（全部在 `/usr/local/bin`）：
  - `droiddeck-dms-supervisor` — 等 niri socket，用干净环境拉起 DMS，掉线重拉，并给 DMS 打 `AudioService.qml` 补丁
  - `dd-nmmock` / `dd-nmmockd` — 用 python3 + libdbus 冒充 `org.freedesktop.NetworkManager`，把 Android 的 Wi-Fi 状态喂给 DMS
  - `dd-bluez` — 冒充 `org.bluez`，把 Android 蓝牙适配器与已配对设备喂给 DMS
  - `pactl` — 包装 `LC_ALL=C /usr/bin/pactl`，让 DMS 的英文正则能解析
  - `droiddeck-selfcheck` — 29 项运行时自检
- **音频**：PulseAudio 13（由 App 侧提供 socket）+ `module-directaudio-native-sink`（`DirectAudio`）/ `module-pipe-source`（`DirectAudioMic`）

不包含：`/root`、`/home`、`/proc`、`/sys`、`/dev`、`/run`、`/tmp`、`/var/cache/pacman/pkg`、`/var/log`，以及 `/data`（Android 侧路径，打包时会递归）。

## 打包与发布

```bash
# 从设备的 files/linuxfs 打包（在 WSL/Linux 上跑）
tools/package-linuxfs.sh --root /path/to/linuxfs --version 2026.11 \
  --out dist/ --base-url https://github.com/<owner>/linuxdesk-components/releases/download
```

脚本会生成 `linuxfs-arch-2026.11.tar.zst` 与配套的 `linuxfs-arch.json`（含 sha256），然后把 tar 作为 **Release asset** 上传（仓库本身只放 catalog 与小文件，GitHub 单文件上限 100 MB）。

```bash
GH_TOKEN=... OWNER=<owner> REPO=linuxdesk-components ./upload.sh
```

## 已知遗留

- niri 每秒输出一条 `Creating new Output name="" physical 0x0`（`waylandcomp` 每秒重播 output），不影响使用
- 桌面模式下 `grabDesktopMouse()` 仍会向 guest 发一次 RightCtrl 假按键