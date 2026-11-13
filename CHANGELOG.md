# 更新日志

本仓库只记录运行时（rootfs）与 catalog 的变化；App 自身的改动在 App 仓库。

## 2026.11.13 — App 预览版

只改 App，运行时与 catalog 仍是 `2026.11`。

- 图形化软件商店：约九十款包的目录、八个分类、中英双语说明、详情页、安装/卸载与实时日志
- 自检页新增「系统更新」：数 `pacman -Qu`、按需执行 `pacman -Syu`，输出实时显示（DMS 自带的更新页依赖 `pkexec`，在 proot 里用不了）
- 修正商店安装：pacman 之前没有拿到 fake root，装包失败却把界面标成「已安装」；现在返回码真实、装不上就是装不上
- 左栏整理为 桌面 / 商店 / 配置 / 自检 四项，移除「版本更新」

## 2026.11 — 首个公开版本

首个可用的 Arch Linux ARM 运行时，目标是"装上 App 就能进一个真正能用的 Linux 桌面"。

**桌面**

- niri 26.04 + DankMaterialShell（`dms` + `qs`）全套可用：顶栏、Dock、控制中心、设置、应用启动器
- 桌面 1:1 铺满屏幕（`displayResolution.<mode> = screen` 时按屏幕原生分辨率，Redmi K Pad 上为 3008×1880）
- 会话入口改为由 App 侧的 `startupSession=desktop` 直接拉起，不再需要手工脚本

**图形**

- Mesa EGL 采用 kopper 补丁版：zink 自建 VkSwapchain 走 dmabuf，取代 `wl_shm` 拷贝
- 保留原版 EGL 与 `/opt/egl-orig/`，DMS 用原版（llvmpipe）启动，避免两个 Venus 客户端导致 niri 段错误
- Venus（`libvulkan_virtio.so` ↔ Android 侧 `libvirgl_test_server.so`）作为默认 Vulkan 通路

**音频**

- 修复"DMS 显示静音且无法调节"：根因是中文 locale 让 DMS 的 `pactl` 解析正则失效，
  随包提供 `pactl` 包装（`LC_ALL=C`）
- 补上麦克风：`RECORD_AUDIO` 授权 + `mic=true` 后出现 `DirectAudioMic`（`module-pipe-source`）
- `AudioService.qml` 补丁提供 `DirectAudio`/`DirectAudioMic` 兜底节点，使 DMS 音频页能列出设备并调音量

**网络**

- 新增 `dd-nmmock`：用 python3 + ctypes 直接调 libdbus，冒充 `org.freedesktop.NetworkManager`，
  实现 `GetManagedObjects`/`GetAllDevices`/`Settings.Connection.GetSettings`/`AgentManager.Register`/
  `Device.Wireless.GetAllAccessPoints`，把手机当前 Wi-Fi 反映到 DMS
- 修掉一个隐蔽 bug：`Properties.Get` 不分接口，导致 `AccessPoints` 返回错误消息体，
  DMS 侧报 `dbus.Store: length mismatch`，`wifiConnected` 永远为 false

**蓝牙**

- 新增 `dd-bluez`：冒充 `org.bluez`，提供适配器与已配对设备列表

**随包工具**

- `droiddeck-selfcheck`（27 项）：二进制、随包脚本、EGL 补丁 md5、Venus socket、niri/DMS/quickshell
  socket、PulseAudio 与两个节点、两个 D-Bus 服务、手机网络状态
- `droiddeck-repair`：幂等修复；桌面没在跑时会以画中画方式拉起桌面再修
- 自检与修复的输出分别落在 `files/logs/tools/selfcheck.log` 与 `repair.log`

**已知问题**

- niri 每秒打印一条 `Creating new Output name="" physical 0x0`（不影响使用，日志噪声）
- 桌面模式下会向 guest 发一个无用的 RightCtrl 假按键（Steam 会话抓取逻辑的遗留）