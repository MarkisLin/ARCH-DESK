# 渲染通路：为什么是 kopper + Venus

这份笔记解释运行时里那套"看起来绕"的图形栈，以及为什么不能简单地退回软件渲染。

## 链路总览

```
Arch 桌面进程（niri / DMS / 应用）
        │  EGL + GLES
        ▼
Mesa  ── zink ──► Vulkan
        │            │
        │            ├─ libvulkan_virtio.so（Venus ICD）
        │            │        │  unix socket: files/venus/vtest.sock
        │            │        ▼
        │            │  Android 侧 libvirgl_test_server.so ─► Mali-G925
        │            │
        │            └─（备选）vkbridge：droidbridge ICD 直接调 Mali Vulkan
        ▼
老板 path：EGL 把每一帧拷进 wl_shm，交给 App 的合成器（waylandcomp）
新 path：kopper 让 zink 自建 VkSwapchain，用 dmabuf 直接把 buffer 交给合成器
```

## 两个必须知道的坑

### 1. Mesa 默认不会在嵌套 Wayland 里用 GPU

`dri2_initialize_wayland()` 只有在拿到 `wl_drm`、或 `fd_render_gpu != -1` 时才会走硬件路径。
在 App 的嵌套合成器里两者都没有，于是 Mesa 直接落到 `swrast`，所有 GL 变成 CPU 渲染，
再经 `wl_shm` 拷贝上屏——表现就是"能显示但极卡、拖影、掉帧"。

补丁做两件事（都在 `libEGL_mesa.so.0.0.0` 里，二进制层面）：

| 偏移 | 原指令 | 改成 | 作用 |
| --- | --- | --- | --- |
| `0x30948` | `cbnz w0, ...` | `b ...` | 强制 `driver_name = "zink"`，跳进 kopper 分支 |
| `0x309d0` | `mov w1, #1` | `mov w1, #0` | `dri2_setup_device(disp, false)`，不要求 render node |

代价：这是二进制补丁，Mesa 升级会被覆盖。所以运行时里同时保留
`libEGL_mesa.so.0.0.0.orig` 与 `/opt/egl-orig/`，并且 `droiddeck-selfcheck` 会用 md5 检查补丁是否还在。

### 2. 一个 Venus 客户端已经很勉强，两个会互相踩

Venus 的 vtest 通路是单服务端多客户端，niri（合成器）已经占了一个。DMS/quickshell 若也走
Venus，niri 会在几秒内 `SIGSEGV`（日志里没有 panic，只有 `ContextLost(EGLSwapBuffers(...))` 之类）。

所以 DMS 是**故意**用原版 EGL（`LD_LIBRARY_PATH=/opt/egl-orig`）以 llvmpipe 启动的：
DMS 只画顶栏、Dock、面板，软件渲染完全够用，还能避免抢 Vulkan。

`droiddeck-dms-supervisor` 因此必须：

1. 等 `niri.wayland-*.sock` 出现，并从文件名反推 `WAYLAND_DISPLAY`
2. `env -u MESA_LOADER_DRIVER_OVERRIDE -u GALLIUM_DRIVER -u VK_ICD_FILENAMES ...`
   —— 会话环境里这些变量会把 Mesa 推回 zink→Venus，即使 `LD_LIBRARY_PATH` 已经指向原版 EGL
3. 之后才 `dms run`

第 2 步是最容易踩的：漏掉任何一个变量，DMS 的进程都活着、`niri msg layers` 也能看到
`dms:bar`/`dms:dock`，但永远不提交帧，日志里一个错误都没有。

## 检查渲染是否真的在 GPU 上

```bash
# guest 内
niri msg outputs          # 应看到 3008x1880 @ 60Hz
glmark2-es2-wayland -b build   # GL_RENDERER 应是 zink Vulkan 1.3(Virtio-GPU Venus ...)
```

如果 `GL_RENDERER` 是 `llvmpipe`，说明 EGL 又回到原版了，用自检页的 `egl-patched` 一项确认。

## 与输入相关的一点背景

渲染之外，输入也是"两套管线"，容易在移植时踩到：

- 触摸：Android `MotionEvent` → App 换算到 1920×1080 的输入空间 → 合成器当**绝对指针**用
  （手指落点就是指针落点，按下去就是点击）
- 鼠标：Android 的 pointer capture 把相对位移交给 App → 合成器发 `zwp_relative_pointer`
  与 `wl_pointer.motion`

如果合成器把相对位移"消费"掉了又不再补发绝对 motion，就会表现成"鼠标动了但指针不动"。
这一层在 App 的 `waylandcomp` 里，不属于本仓库的 rootfs。