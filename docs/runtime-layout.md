# 运行时目录导览

解压后的 rootfs 就是一棵普通的 Arch Linux ARM 树，外加几处为本项目准备的固定位置。
这里只列"看代码时需要知道在哪"的部分。

```
/etc/arch-release                  Arch 身份文件（自检用它判断是不是 Arch）
/etc/os-release                    PRETTY_NAME 被改写成 "Arch Linux ARM"，DMS 与系统信息读它
/etc/pacman.conf                   关掉 DownloadUser / CheckSpace / 沙箱选项（proot 里跑不了）
/etc/pacman.d/mirrorlist           国内镜像（清华 / 阿里 / 官方）

/usr/bin/niri                      Wayland 合成器
/usr/bin/dms                       DankMaterialShell 的 Go 二进制（顶栏、设置、IPC 都在里面）
/usr/bin/qs                        quickshell，DMS 的 QML 运行时
/usr/bin/startlxqtwayland          会话入口：GPU 环境 → EGL 补丁 → 拉起 supervisor → exec niri

/usr/local/bin/droiddeck-dms-supervisor   DMS 的启动与守护（干净环境、掉线重拉、音频补丁）
/usr/local/bin/dd-nmmock                  org.freedesktop.NetworkManager 的替身（python3 + libdbus）
/usr/local/bin/dd-nmmockd                 上面那个的保活壳
/usr/local/bin/dd-bluez                   org.bluez 的替身
/usr/local/bin/pactl                      包装成 LC_ALL=C 的 pactl
/usr/local/bin/droiddeck-selfcheck        27 项自检
/usr/local/bin/droiddeck-repair           幂等修复

/usr/local/share/droiddeck/AudioService.qml.patched   DMS 音频后端的补丁文件
/usr/local/share/droiddeck/os-release                /etc/os-release 的模板
/usr/local/lib/droiddeck/libEGL_mesa.so.0.0.0.patched kopper 补丁版 EGL
/usr/local/lib/droiddeck/libEGL_mesa.so.0.0.0.orig    原版 EGL
/opt/egl-orig/libEGL_mesa.so.0                        指向 .orig 的软链（DMS 用）
/opt/egl-orig/libEGL_mesa.so.0.0.0                    同上

/usr/share/vulkan/icd.d/virtio_icd.json               Venus ICD 清单
/usr/lib/libEGL_mesa.so.0                             必须指向 libEGL_mesa.so.0.0.0
/usr/lib/libEGL_mesa.so.0.0.0                         通常是补丁版（niri 用）
/usr/lib/libEGL_mesa.so.0.0.0.orig                    原版备份
```

## 运行时才出现的东西

这些不打包、不持久，每次会话由 App 或脚本生成：

| 路径 | 谁写 | 内容 |
| --- | --- | --- |
| `$XDG_RUNTIME_DIR/niri.wayland-*.sock` | niri | niri 的 IPC socket，名字里的 pid 用来反推 `WAYLAND_DISPLAY` |
| `$XDG_RUNTIME_DIR/dms-*.sock` | dms | dms 的 IPC，`dms ipc call ...` 走它 |
| `$XDG_RUNTIME_DIR/quickshell/by-id/*` | quickshell | 每个 shell 实例的日志与状态 |
| `$XDG_RUNTIME_DIR/dms-shell/<hash>/Services/` | dms 启动时自解包 | QML 源文件，`AudioService.qml` 的补丁打在这里 |
| `/root/.cache/droiddeck/netinfo` | App | 手机当前网络（type/iface/ssid/ip/gw/dns/freq/rssi） |
| `/root/.cache/droiddeck/btinfo` | App | 手机蓝牙适配器与已配对设备 |
| `/root/.cache/droiddeck/run/*.sh` | 调试用 | 会话内每秒执行一次并自删，用来在 guest 里跑一次性命令 |

`XDG_RUNTIME_DIR` 在会话里是 `/run/droiddeck`（App 的 bind mount），
在一次性 proot 里则是 `files/.wayland-rt`（自检与修复脚本会自己回落到这里）。

## 一次会话的启动顺序

1. App 起 PulseAudio（`files/pulseaudio/PS0`）与 Venus 的 vtest server（`files/venus/vtest.sock`）
2. App 写 `netinfo` / `btinfo`，proot 进入 rootfs，执行 `/usr/bin/startlxqtwayland`
3. `startlxqtwayland`：检查 EGL 补丁与符号链接 → 导出 GPU 环境 → `setsid` 起 `droiddeck-dms-supervisor` → `exec niri`
4. supervisor：等 niri socket → 起 `dd-nmmockd`、`dd-bluez`（会占 system bus 的名字）→ 起 `dms run`
5. dms：解包 QML 到 `dms-shell/<hash>/`，supervisor 打音频补丁后重启一次 dms，顶栏与面板出图