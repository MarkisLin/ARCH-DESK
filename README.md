# ARCH DESK

Arch Linux ARM on an Android tablet: niri as the compositor, DankMaterialShell on top, applications
drawing with the tablet's own GPU. No root, no unlocked bootloader, no virtual machine.

English | [简体中文](README.zh-CN.md)

| | |
| --- | --- |
| Platform | Android 8.0+, `arm64-v8a`. Developed on Android 16 |
| Root | not required; the guest runs under PRoot |
| Desktop | niri 26.04 + DankMaterialShell 2.1 |
| Graphics | Mesa zink → Vulkan (Venus) → Mali-G925, presented as dmabufs |
| Disk | ~830 MB – 1.76 GB download, ~4.8 GB installed |
| First run | 10–20 min over a normal connection |

This repository holds the catalogs the app reads, the script that turns a stock Arch Linux ARM
tarball into a desktop, and a prebuilt runtime for people who would rather skip that step. The app
and the native compositor live in the app repository.

## Why

A tablet already contains the machine people buy a laptop for: eight cores, a current GPU, more
memory than a netbook, and a 3K screen. What it does not contain is a way to use any of that for
anything other than a phone app. One app fills the screen, files stay inside the app that made them,
and there is no shell, no compiler, no window manager.

The usual escapes each give something up:

| Escape | What it costs |
| --- | --- |
| SSH into a server | needs a server and a connection; the tablet's own hardware sits idle |
| Termux | a terminal, not a desktop; no window management, no accelerated session |
| DeX / desktop mode | still Android apps, so the software a desktop needs is still missing |
| Cloud desktop | latency, bandwidth, a subscription, and nothing offline |
| Emulator | emulates the CPU, so everything runs slower than the tablet can |
| Virtual machine | not available on retail devices without unlocking the bootloader |

This project takes the remaining option: run what already exists for Linux on ARM, natively, on the
tablet's own hardware, without root and without a VM. The parts are there — Arch Linux ARM has an
aarch64 build of nearly everything, and the GPU is reachable through Vulkan. What was missing was the
plumbing between them, and a way to keep that plumbing working after updates.

That second half is why the repository is shaped the way it is: a recipe and a small set of patches,
rather than a frozen image that nobody can maintain.

## Hardware

A mid-range 2026 tablet has eight cores, a recent GPU, 8–16 GB of RAM and a 3K screen. That is more
than the laptop most people browse on. Android hands all of it to a phone UI, and the usual ways of
getting a desktop out of it either emulate the CPU or draw with the CPU:

| | CPU | Renderer |
| --- | --- | --- |
| PC emulator (QEMU/TCG) | x86 translated to ARM | software, SwiftShader |
| Termux + X11 | native | `llvmpipe` |
| Remote desktop | remote | none locally |
| ARCH DESK | native aarch64 | Vulkan on the Mali GPU |

On the test device (MediaTek MT8799, 8 cores, 16 GB) the guest runs native instructions. PRoot
rewrites path syscalls in user space and nothing else, so `gcc`, `pacman` and video decoding all run
at the speed of the SoC. The only thing that had to be rebuilt is graphics, because Android gives a
container no DRM node to render into, and the Mali kernel driver is not exposed the way a Linux
desktop expects.

### How the Mali GPU is used

1. The guest gets a Vulkan ICD that speaks Venus (`vulkan-virtio`,
   `/usr/share/vulkan/icd.d/virtio_icd.json`), selected with `VK_ICD_FILENAMES`. Every Vulkan call
   is serialised into the Venus protocol.
2. That driver talks to `files/venus/vtest.sock` in the app's private storage. No `/dev` node is
   involved.
3. The APK ships `libvirgl_test_server.so` and starts it from its own `nativeLibraryDir`, inside the
   app process. Starting it there is what keeps it alive across app updates.
4. The server decodes Venus commands and calls the tablet's real Vulkan driver, so work lands on the
   GPU.
5. Rendered images come back as dmabuf file descriptors and are imported in the guest as EGL images,
   without a round trip through CPU memory.
6. Mesa's EGL is patched to select `zink` and let kopper build its own `VkSwapchain`. Frames travel
   as dmabufs into the host compositor and then into the Android surface.

Step 6 is the one that makes or breaks the desktop. Without the patch Mesa decides there is no DRM
and no Wayland buffer path, loads `swrast`, and copies every frame through `wl_shm`. On a 3K panel
that looks like black windows at a few frames per second, with the GPU idle.

You can check which path is active from inside the guest:

```console
$ glmark2 -b build
GL_RENDERER: zink Vulkan 1.3(Virtio-GPU Venus (Mali-G925-Immortalis MC12))
```

`llvmpipe` or `softpipe` in that line means the patch is missing; the self-check page reports the
same thing as `egl-patched`.

## What it is for

The goal is not to boot Linux on a tablet and take a screenshot. It is to make the tablet behave like
the Linux machine it already is: a desktop that lasts a working day, keeps the GPU busy, accepts
touch and a mouse the way people expect, and leaves `pacman` working so the system can be maintained
instead of frozen at whatever shipped.

That produced a list of acceptance criteria, and most of the work described below exists because one
of them failed:

- the compositor runs on the GPU, confirmed by the renderer string and not by how it feels;
- the screen is filled at its native 3008 × 1880, with no letterboxing and no client-side title bar;
- a tap lands where the finger is, and an external mouse drives the same pointer;
- sound plays, the microphone records, and the shell's slider changes the real volume;
- the session starts from the app without a terminal, and still starts after the app is reinstalled;
- a check inside the guest can tell a broken install from a working one.

## How it is put together

Four layers, each with one job:

| Layer | Where | Job |
| --- | --- | --- |
| Guest runtime | `files/linuxfs` | the Arch system: niri, the shell, Mesa, and whatever the user installs |
| Session scripts | APK assets, staged on every launch | entry point, supervisor, audio/network/Bluetooth bridges, check and repair |
| Provisioning | `archdesk-provision` and `packages.txt` | turn a stock tarball into that runtime, and repair drift later |
| Catalogs | this repository | tell the app what to download and how to verify it |

Scripts are staged out of the APK on every launch instead of being edited in place. The runtime is
disposable: an update replaces it wholesale, so anything that has to survive belongs in the app. In
the source tree the copy that counts is `linuxdesk/tools/linuxfs/overlay`; Gradle regenerates the
asset directory from it before every build, which is why editing assets alone appears to do nothing.

A session starts in this order:

1. The app extracts or primes the runtime, then starts PulseAudio and the Venus test server inside
   its own process.
2. `startlxqtwayland` sets the guest environment (ICD, audio socket, session socket), re-applies the
   EGL patch and its symlink, provisions on first boot, launches the desktop supervisor detached,
   and `exec`s niri.
3. The supervisor waits for niri's socket, derives `WAYLAND_DISPLAY` and `NIRI_SOCKET` from the
   socket name, clears the GL variables, and starts the shell against the pristine EGL. It restarts
   the shell if it dies, and patches the shell's audio service once the shell has unpacked it.
4. Two small services claim the NetworkManager and BlueZ bus names and answer from Android state.
5. The app's compositor presents the guest surfaces.

## How this was developed

Every subsystem went through the same loop, because guessing is expensive here: a wrong guess costs a
build, an install and a session restart.

1. Measure before changing anything. Frame problems were measured by counting distinct colours and
   sampling specific pixels, not by judging a screenshot. `64,64,64` across the screen means an
   unpainted surface; the bar has known colours; a region that used to hold a watermark has exactly
   one colour once it is gone.
2. Find the single link that is wrong. The desktop once painted nothing while every process was
   alive, every layer was registered and the log was empty. That combination points at the client
   being pushed onto the wrong GPU path, not at the shell.
3. Change that link and measure again.
4. Leave a check behind, so the next person can tell a broken install from a working one.

The expensive mistakes are recorded in `docs/rendering.md` and in the commit history, because they
cost more than the successes did:

- The first EGL patch hit `dri2_initialize_wayland_drm`, a branch the software renderer never takes,
  so it changed nothing.
- A patch that should have worked appeared to do nothing because `libEGL_mesa.so.0` still pointed at
  the unpatched file.
- Sending one `wl_output` object to every client is a protocol violation. niri died with
  `ContextLost` and took the session with it; each client has to receive the output object belonging
  to its own connection.
- The shell painted nothing while its layers were registered, because session-wide zink variables
  pushed it back onto the Venus path. Clearing the environment and giving it a second EGL fixed it.
- A relative-pointer binding made the compositor swallow absolute motion, so the cursor never moved
  although events arrived. Removing one condition in the motion path fixed it.
- A frozen runtime image was easy to publish and impossible to maintain. The official tarball plus a
  provisioning script replaced it.

## Install

| What | Link |
| --- | --- |
| APK, arm64 | [ARCHDESK-debug.apk](https://github.com/MarkisLin/ARCH-DESK/releases/download/app-2026.11.13/ARCHDESK-debug.apk) |
| Official catalog (default) | [`linuxfs-arch-official.json`](linuxfs-arch-official.json) |
| Prebuilt runtime, 1.76 GB (optional) | [release `linuxfs-2026.11`](https://github.com/MarkisLin/ARCH-DESK/releases/tag/linuxfs-2026.11) |

The APK is signed with a test key and marked debuggable, because that is the build the tablet runs.
There is no store listing and no update channel yet.

1. Install the APK and open it.
2. Grant notifications, microphone and location when asked. The microphone permission decides whether
   `DirectAudioMic` exists; location is what lets the Wi-Fi panel show details.
3. Press **打开桌面 / Open desktop**. The app downloads the official Arch Linux ARM tarball, unpacks
   it, and provisions it on first boot.
4. Later launches go straight to the desktop if "start desktop at launch" is on.

| | Official (default) | Prebuilt |
| --- | --- | --- |
| Download | ~830 MB | 1.76 GB |
| First run | 10–20 min, network-bound | 2–4 min |
| `pacman -Syu` works right away | yes | yes, after the first upgrade |
| Offline after setup | yes | yes |

Around 6 GB of free space is needed. Downloads resume if interrupted, and the app checks the size
(and the SHA-256, when the catalog publishes one) before touching an existing installation.

Three tools sit in the left rail: the store, the setup page and the check page. The check covers about thirty items; items that only exist while a
session is running are reported as `SKIP` when the desktop is stopped, instead of failing. Repair is
idempotent: it restages the shipped scripts, restores the EGL patch and its symlinks, rewrites
`/etc/os-release`, reinstalls the `pactl` wrapper, re-applies the shell's audio patch and restarts the
D-Bus bridges. If nothing is running it raises the desktop in picture-in-picture, does the work, and
dismisses it.

## What the desktop is

- **niri** for window management. Scrollable tiling suits a tablet: every window gets a full-height
  column, and horizontal scrolling is a gesture people already make on a touchscreen.
- **DankMaterialShell** for the bar, dock, control centre and settings. It is an ordinary Wayland
  client, so a shell crash does not take the session with it.
- **Touch** moves the pointer to the finger and presses there. It is not a trackpad; the old
  trackpad behaviour made taps land wherever the pointer happened to be.
- **A physical mouse** goes through pointer capture: the app receives raw relative deltas and
  forwards motion, buttons and wheel into the guest. Both input paths end in the same compositor
  pointer.
- **Audio** comes from PulseAudio running inside the app. The sink writes into an `AudioTrack`, so
  the guest sees `DirectAudio`, and a pipe source fed by the app's recorder shows up as
  `DirectAudioMic`.
- **Network and Bluetooth panels** are fed by two small services that hold the
  `org.freedesktop.NetworkManager` and `org.bluez` bus names and answer with what Android reports.
  They describe; they do not connect.

## Apps and updates

The app carries a catalogue of about ninety packages (`store.json`), sorted into eight categories,
with a short description in Chinese and English for each. Installing from it runs `pacman -S` inside
a fake-root proot, so the package lands in the same root filesystem the desktop boots from; once the
package writes its `.desktop` file it shows up in the launcher. Packages outside the catalogue are
still one `pacman` command away in a terminal.

System upgrades live on the check page: it counts `pacman -Qu` when the page opens and runs
`pacman -Syu` on demand, streaming the output into the card. DMS has its own software-update page,
but it calls `pkexec`, which needs a real setuid binary and polkit — that page cannot work here.

## Verified hardware

| Device | SoC / GPU | Android | Status |
| --- | --- | --- | --- |
| Redmi K Pad (`25079RPDCC`) | MediaTek MT8799, Mali-G925-Immortalis MC12 | 16 | Daily use: niri + shell, Chromium, VLC, terminals, audio in and out, mouse and touch |

Nothing else has been tried. The assumptions that could break on another device: a Vulkan driver
that accepts Venus, dmabuf export from the GPU, and 4 GB of free space. Without a working Vulkan ICD
the guest falls back to software rendering.

## Design choices

- **PRoot instead of chroot.** Retail devices have no root, and unlocking the bootloader costs the
  warranty, Play Integrity, and on some devices the camera. The price is no namespaces, no `mount`,
  no real `/proc`, no `setuid`.
- **Patch the EGL loader instead of rebuilding Mesa.** A two-instruction change plus a wrapper that
  re-applies it after `pacman` upgrades; building Mesa for aarch64 on the device is slow and breaks
  on the next version.
- **Two EGLs.** niri needs the patched, GPU-backed one. The shell runs on llvmpipe with a pristine
  copy from `/opt/egl-orig` and a scrubbed environment, because sharing one Venus client between them
  segfaults both.
- **Official tarball plus a provisioning script instead of a frozen image.** A frozen image is
  easier to publish and impossible to maintain. Provisioning keeps `pacman` useful, so users can
  install their own software and the runtime keeps receiving upstream fixes.
- **Bridges instead of porting NetworkManager and BlueZ.** Those need netlink, D-Bus policy and
  kernel modules that PRoot cannot provide. Reporting Android's state over the same bus names covers
  what the panels show.

## Limitations

- **No sandboxing.** PRoot does not create namespaces, so `bwrap`, Chromium's zygote sandbox and
  QtWebEngine's sandbox cannot work. The runtime ships a `bwrap` shim and launch wrappers pass
  `--no-sandbox`; the security boundary is the Android app sandbox.
- **The GPU is indirect.** There is no `/dev/dri` render node, so applications that require GBM or
  probe for DRM will fail. Everything renders through Vulkan.
- **No systemd.** Services are scripts supervised by the session; no timers, no socket activation,
  no dependency ordering.
- **Background limits.** Android may kill the session under memory pressure, and background UIDs are
  blocked from the network, which is why installing runs with a foreground notification.
- **Panels are read-only.** The shell can show the current network and paired Bluetooth devices, but
  cannot scan for new networks or pair new devices.
- **One sink, one source.** No per-app routing, no HDMI, no multiple microphones.
- **Nested presentation.** The guest renders into a surface that Android composites again. There is
  a small per-frame cost and no HDR.
- **The EGL patch needs upkeep.** It is tied to one Mesa major version's loader layout. A large
  `pacman -Syu` can invalidate it; the self-check notices and the repair tool restores the file, but
  the patch has to be re-derived eventually.
- **One SoC tested.** Everything was developed against Mali. Adreno is untested.
- **LibreOffice does not start yet.** It exits on `ERROR: /proc not mounted`.

## Roadmap

The direction is to stop owning a frozen image and start owning a recipe. A recipe can be re-run,
diffed and repaired; an image can only be downloaded again.

- Provision without keeping the app in the foreground.
- Ship `dms`, quickshell and the patches as `pacman` packages from a signed repository, so the
  desktop updates with the system.
- Publish the app source and a release-keyed build.
- Finish the hardware panels, or hide the parts that cannot work instead of showing empty lists.
- Fix the LibreOffice `/proc` failure and the `Creating new Output` churn in niri.
- Longer term: a real init inside the guest, zero-copy presentation, external displays and
  keyboards, and a container or VM path where the platform allows one.

## Repository layout

```
.
├── README.md                    English
├── README.zh-CN.md              Chinese
├── linuxfs-arch-official.json   default catalog: official tarball + provisioning
├── linuxfs-arch.json            fallback catalog: prebuilt runtime
├── docs/
│   ├── rendering.md             graphics pipeline, kopper, checking the GPU
│   ├── runtime-layout.md        where files live, session start order
│   └── publishing.md            packaging, releases, rollback
└── CHANGELOG.md
```

Catalog fields:

| Field | Meaning |
| --- | --- |
| `version` | `YYYY.MM`; compared with what is installed |
| `kind` | `official` (stock tarball + provision) or `rootfs` (prebuilt) |
| `format` | `tar.gz` or `tar.zst` |
| `url` | direct download |
| `sha256` | optional for `official`, required for `rootfs` |
| `size` | bytes |

## Credits

This project started as a fork of [DroidDeck](https://github.com/Droid-Deck/DroidDeck) 0.6.9, which
was built to run Steam Gaming Mode on Android. The rendering approach comes from there: a Wayland
compositor inside the app that presents guest surfaces into an Android surface, the Venus/virgl
bridge that routes Vulkan to the vendor driver over a socket, and the proot session layout under
`files/linuxfs`. ARCH DESK keeps the package id and the `droiddeck-*` script names so existing
installs can be upgraded in place.

What changed for a desktop rather than a gaming shell: the session is niri plus DankMaterialShell
instead of gamescope; the EGL loader is patched for kopper and the shell runs on a second, pristine
EGL; touch is an absolute pointer instead of a trackpad; pointer capture was rewired so a mouse
actually moves the guest pointer; the network and Bluetooth panels are fed from Android; the runtime
is installed from the official tarball with a provisioning script; and the app gained self-check and
repair.

Everything else is other people's work: Arch Linux ARM, niri, DankMaterialShell and quickshell, Mesa,
virglrenderer and the Venus protocol, and the packages those depend on.

## License

Packages inside the runtime keep their upstream licenses. The scripts, catalogs and documentation in
this repository are meant to be MIT; the `LICENSE` file is not in place yet, so treat that as an
intention rather than a grant.