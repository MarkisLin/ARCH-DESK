# ARCH DESK

**A real Arch Linux ARM desktop — niri + DankMaterialShell — running on an Android tablet.
No root. No unlocked bootloader. No virtual machine.**

English | [简体中文](README.zh-CN.md)

---

ARCH DESK turns an ordinary Android tablet into a Linux workstation. The user space is a genuine
Arch Linux ARM aarch64 installation: `pacman`, the rolling release, system libraries, the whole
thing. The desktop is a genuine Wayland session: niri as the compositor, DankMaterialShell (DMS)
as the shell, applications rendering through the tablet's own GPU.

Nothing is emulated and nothing is streamed. The only Android-specific pieces are the transport
between the two worlds: a Wayland compositor that presents the guest session into an Android
`Surface`, a Vulkan bridge that hands GPU work to the vendor driver, and a small set of bridges so
the desktop can see the hardware Android owns (audio, network, Bluetooth, input).

This repository is the **distribution channel** for that user space: the catalogs the app reads,
the provisioning recipe that turns a stock Arch Linux ARM tarball into a desktop, and the prebuilt
runtime for people who would rather skip the first-run setup.

| | |
| --- | --- |
| Platform | Android 8.0+ (`arm64-v8a`), validated on Android 16 |
| Root | **Not required** — the guest runs under PRoot |
| Desktop | niri 26.04 + DankMaterialShell 2.1 |
| Graphics | Mesa `zink` → Vulkan (Venus) → Mali-G925, dmabuf presentation |
| Install size | ~4.8 GB unpacked, ~830 MB – 1.76 GB download |
| First run | 10–20 min on a normal connection |

---

## Table of contents

- [Why this exists](#why-this-exists)
- [How it works](#how-it-works)
- [What is in this repository](#what-is-in-this-repository)
- [Installing](#installing)
- [Verified hardware](#verified-hardware)
- [Design decisions](#design-decisions)
- [Known limitations](#known-limitations)
- [Roadmap](#roadmap)
- [Repository layout](#repository-layout)
- [License](#license)

---

## Why this exists

A modern tablet has more compute than the laptop most people browse the web on: eight cores, a
recent GPU, 8–16 GB of RAM, a 3K display, and a battery that lasts a day. Android gives all of that
to a phone UI. The existing escape hatches are unsatisfying:

| Approach | What it gives you | What it does not |
| --- | --- | --- |
| SSH / VNC into a remote machine | A real desktop | Needs a network, adds latency, uses no local GPU, dies without Wi-Fi |
| Termux + X11 | A shell, some GUI apps | No compositor, software rendering, no window management worth the name |
| Vendor "desktop mode" (DeX and friends) | Polished Android windows | Closed, not Linux, no `pacman` |
| Cloud gaming / remote Linux | Convenience | Not your machine, not offline, not free |

ARCH DESK's bet is simpler: **the tablet can be the computer**, if a real Wayland session can run
next to Android with GPU acceleration and shared hardware. Root would make that easy; root is not
available on most devices people actually own, so the interesting engineering is doing it without.

## How it works

### The two halves

```
┌─────────────────────────── Android app (Kotlin/Compose) ───────────────────────────┐
│  Front end (Compose)      Session service            Native side (C / NDK)         │
│  ├ install / self-check   ├ PRoot supervisor         ├ waylandcomp  (compositor)   │
│  ├ settings               ├ Venus vtest server  ◄──────── wl_socket ───────────┐   │
│  └ picture-in-picture     ├ PulseAudio          ◄──────── pulse socket ────┐   │   │
│                           └ input / pointer capture                       │   │   │
│                                    │                                      │   │   │
│                                    ▼                                      │   │   │
│                          Android Surface ──► SurfaceFlinger ──► panel    │   │   │
└───────────────────────────────────────────────────────────────────────────┼───┼───┘
                                                                            │   │
┌──────────────────────────── Arch Linux ARM (PRoot) ───────────────────────┼───┼───┐
│  niri (Wayland compositor)  ◄── wayland client ───────────────────────────┘   │   │
│  ├─ DankMaterialShell (dms + quickshell/Qt6)                                  │   │
│  ├─ applications (Chromium, VLC, LibreOffice, terminals, …)  ◄── audio ───────┘   │
│  └─ pacman, systemd-free service scripts                                          │
└───────────────────────────────────────────────────────────────────────────────────┘
```

The guest believes it is talking to a normal Wayland compositor, a normal PulseAudio server and a
normal set of D-Bus services. It is; they just happen to live in the Android process.

### The rendering chain

There is no DRM device and no `/dev/dri` render node for the guest, and the Mali kernel driver is
not exposed to user space the way a Linux desktop expects. So the chain is rebuilt around Vulkan:

```
GL app ──► Mesa zink ──► Vulkan ──► Venus (virtio-gpu) ──► vtest socket
                                                              │
                       Android: libvirgl_render_server ──► Mali-G925 ──► dmabuf
                                                              │
                            waylandcomp takes the dmabuf ──► Android Surface ──► screen
```

Two details matter more than the rest:

**kopper.** Mesa's EGL on Wayland normally wants a DRM render node or `wl_drm` to hand out buffers.
We have neither, so upstream Mesa decides the driver cannot work, falls back to `swrast`, and the
session ends up copying every frame through `wl_shm` — which on this hardware means black frames
and single-digit frame rates. The fix is to make Mesa pick `zink` and let **kopper** build its own
`VkSwapchain`, so buffers travel as dmabufs and never touch the CPU. That is a two-instruction patch
to `libEGL_mesa.so.0.0.0` plus a symbol-link fix, shipped inside the runtime and re-applied by the
repair tool if a `pacman` upgrade overwrites it.

**Two EGL personalities.** niri needs the patched (GPU) EGL. DMS is a Qt/quickshell application that
is perfectly happy on llvmpipe, and pointing it at the same Venus client as niri makes both
segfault. So the runtime keeps a pristine copy at `/opt/egl-orig` and the supervisor launches DMS
against it, in a scrubbed environment (`env -u` on `MESA_LOADER_DRIVER_OVERRIDE`, `GALLIUM_DRIVER`,
`VK_ICD_FILENAMES`, …), because those variables alone are enough to drag Qt back onto Venus.

### Input

Touch is not a trackpad here. Tapping the screen puts the pointer where the finger landed and
presses there — the intuitive behaviour on a tablet, and the only one that survives a 3K panel
without a cursor you cannot see. A physical mouse is a different path: the app requests **pointer
capture**, receives raw relative deltas, and forwards them into the guest as relative motion plus
buttons and wheel. Both end up in the same compositor pointer.

### Audio

PulseAudio runs inside the Android app (`libpulseaudio.so`), with a sink module that writes straight
into an `AudioTrack`. The guest sees a normal PulseAudio server over a Unix socket; the sink appears
as `DirectAudio` and the microphone as `DirectAudioMic` (a pipe source fed by the app's recorder).
Android's volume keys, the app's permissions and the guest's mixer stay in sync.

### System services

DMS talks to the system over D-Bus: `org.freedesktop.NetworkManager` for the network panel,
`org.bluez` for Bluetooth. Neither service exists in a PRoot user space. Rather than porting them,
the runtime ships two small stand-ins (`dd-nmmock`, `dd-bluez`) that own those bus names and answer
with the state Android actually has — current SSID, address, gateway, signal, adapter, paired
devices. It is a bridge, not an emulator: it reports, it does not connect.

### Provisioning

The default install path downloads the **official** `ArchLinuxARM-aarch64-latest.tar.gz`, unpacks it,
and runs `archdesk-provision` on first boot. That script fixes what a stock ARM tarball gets wrong
inside a container (DNS via `nsswitch.conf`, a dangling `/etc/resolv.conf` symlink, a `pacman.conf`
that points at a repository which does not exist), installs the 34 top-level packages the desktop
needs (about 400 packages resolved), drops in the pieces that have no Arch package (`dms`, the
patched EGL, the bridges), and records that it is done.

The point is maintainability: the guest is a rolling Arch system, so `pacman -Syu` keeps working and
users can install whatever they like, instead of being frozen inside a hand-built image.

## What is in this repository

| File | Purpose |
| --- | --- |
| [`linuxfs-arch-official.json`](linuxfs-arch-official.json) | Default catalog: official Arch Linux ARM tarball + provisioning |
| [`linuxfs-arch.json`](linuxfs-arch.json) | Fallback catalog: prebuilt 1.76 GB runtime, ready on first boot |
| [`docs/rendering.md`](docs/rendering.md) | Why kopper, why two EGLs, how to prove the GPU is real |
| [`docs/runtime-layout.md`](docs/runtime-layout.md) | Where everything lives, and the order a session starts in |
| [`docs/publishing.md`](docs/publishing.md) | Packaging, releases, catalog updates, rollback |
| [`CHANGELOG.md`](CHANGELOG.md) | What changed, when |

### Catalogs

The app reads `BuildConfig.LINUXFS_CATALOG` and expects:

```json
{
  "version": "2026.11-stock",
  "kind": "official",
  "format": "tar.gz",
  "url": "https://mirrors.aliyun.com/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz",
  "size": 829367415
}
```

| Field | Meaning |
| --- | --- |
| `version` | Human-readable version, `YYYY.MM`; the app compares it with what is installed |
| `kind` | `official` (stock tarball + provision) or `rootfs` (prebuilt image) |
| `format` | `tar.gz` or `tar.zst`; also selects the decompressor |
| `url` | Direct, anonymous download link |
| `sha256` | Optional for `official`, mandatory for `rootfs` |
| `size` | Bytes, for progress and disk-space checks |

### Release assets

- `linuxfs-arch-2026.11.tar.zst` — 1.76 GB prebuilt runtime (4.75 GB unpacked), zstd.
- Provisioning scripts travel inside the APK, not here, so they always match the app version.

## Installing

1. Install the ARCH DESK APK (arm64).
2. Grant notification and "install unknown apps" if prompted; grant microphone and location when
   asked — the first is required for the microphone node, the second for Wi-Fi details.
3. Open the app and press **Open desktop**. The runtime downloads, verifies, unpacks and provisions.
4. The desktop appears. Later launches go straight in, if "start desktop at launch" is enabled.

| | Official (default) | Prebuilt |
| --- | --- | --- |
| Download | ~830 MB | 1.76 GB |
| First run | 10–20 min (network-bound) | 2–4 min |
| Stays updatable with `pacman` | Yes, immediately | Yes, after the first `pacman -Syu` |
| Works offline after setup | Yes | Yes |

Free space needed: about 6 GB. The download resumes if interrupted; the app verifies the size and,
when published, the SHA-256 before touching an existing installation.

### Self-check and repair

Both live in the app's left rail. The check covers roughly thirty items: binaries, shipped scripts,
the EGL patch hash, the Venus socket, niri/DMS/quickshell sockets, PulseAudio and its two nodes, both
D-Bus bridges, and the network snapshot. Items that only exist while a desktop is running are
reported as `SKIP` rather than `FAIL`, so the check is meaningful on an idle tablet.

Repair is idempotent: it re-stages assets, restores the EGL patch and symlinks, rewrites
`/etc/os-release`, reinstalls the `pactl` wrapper, re-applies the DMS audio patch and restarts the
bridges. If no session is running it raises the desktop in **picture-in-picture** to do the work,
then dismisses it.

## Verified hardware

| Device | SoC / GPU | Android | Result |
| --- | --- | --- | --- |
| Redmi K Pad (`25079RPDCC`) | MediaTek MT8799 / Mali-G925-Immortalis MC12 | 16 | Daily driver: niri + DMS, Chromium, VLC, terminals, audio in/out, mouse + touch |

Other devices are untested. The risky assumptions are: a Vulkan driver that accepts Venus, a Mali or
Adreno GPU with dmabuf export, and 4+ GB of free space. Devices without a working Vulkan ICD will
fall back to software rendering and be unusably slow.

## Design decisions

**PRoot, not chroot.** Root is unavailable on retail devices and unlocking the bootloader costs
warranty, Play Integrity and often the camera. PRoot intercepts path-resolving syscalls in user space
and needs no privileges. The cost is real: no namespaces, no `mount`, no real `/proc`, no `setuid`.

**niri, not a floating compositor.** A tablet is a keyboard-less, mouse-less rectangle. Scrollable
tiling gives every window a predictable full-height column, gestures map naturally to horizontal
scrolling, and there is no fiddly window chrome to hit with a finger.

**DankMaterialShell, not a hand-written shell.** Quickshell gives a mature bar, dock, control centre
and settings UI for free, in QML, which is fast to iterate on. It also means the shell is an ordinary
Wayland client, so a shell crash does not take the session down.

**Patched EGL, not a patched Mesa.** Rebuilding Mesa for aarch64 on-device is slow and fragile; two
instruction patches to the EGL loader plus a wrapper that re-applies them survive `pacman` upgrades
and cost nothing at runtime.

**Bridges, not services.** Shipping a full NetworkManager or BlueZ inside a container means D-Bus
policy, netlink access and kernel modules that PRoot cannot provide. Reporting Android's state over
the same bus names gets 95% of the visible value for 5% of the work — and it is honest about what it
cannot do: it does not join networks, it describes the one Android already joined.

**Official tarball + provision, not a frozen image.** A frozen image is easy to ship and impossible
to maintain. Provisioning keeps `pacman` useful, lets users install their own software, and keeps the
delta between releases small.

## Known limitations

These are not bugs on a list; they are the shape of the current design.

- **No sandboxing.** PRoot provides no namespaces, so `bwrap`, Chromium's zygote sandbox and
  QtWebEngine's sandbox cannot work. The runtime ships a `bwrap` compatibility shim and launch
  wrappers pass `--no-sandbox`; the real security boundary is the Android app sandbox (UID + SELinux).
  Electron apps, Chromium-family browsers and anything shipping `chrome-sandbox` need that flag.
- **Indirect GPU.** There is no DRM render node. Applications that probe `/dev/dri` or require GBM
  will not find one. Everything renders through Vulkan/kopper, which is fast but not identical to a
  native Linux GPU stack.
- **No `systemd`.** Services are ordinary scripts supervised by the session. Timers, socket
  activation and dependency ordering do not exist; anything that assumes `systemctl` will not work.
- **Background execution is Android's call.** The system may kill the session under memory pressure,
  and network access is blocked for background UIDs — a download must run with the app in the
  foreground, which is why the installer keeps a foreground notification.
- **Incomplete hardware panels.** DMS can show the current network and paired Bluetooth devices, but
  not scan for new Wi-Fi networks or pair new devices: those operations live behind Android APIs the
  bridges do not call yet.
- **Single sink, single source.** Audio is routed to the default output; per-app routing, HDMI and
  multiple microphones are not modelled.
- **Nested presentation.** The guest compositor renders into a `Surface` that Android then composites.
  There is no direct scanout, so there is a fixed small cost per frame and no HDR.
- **Patch upkeep.** The EGL patch is tied to the `libEGL_mesa` layout of a Mesa major version. A
  `pacman -Syu` that jumps far enough can invalidate it; the self-check detects it and the repair
  tool restores it, but the patch has to be re-derived eventually.
- **One tested SoC.** Everything here was developed against Mali + Venus. Adreno has a different
  Vulkan story and is untested.

## Roadmap

**Near term — make the daily driver boring**

- Provision without the app in the foreground (foreground service + resumable download).
- Replace the "start desktop at launch" guesswork with a proper session lifecycle (survive
  configuration changes, restore after low-memory kill).
- Finish the hardware panels honestly: report what is known, disable what is not supported instead of
  showing an empty list.
- Fix the remaining niri output-recreation churn and the LibreOffice `/proc` startup failure.

**Mid term — make it installable by strangers**

- Ship `dms`, quickshell and the patches as real `pacman` packages from a signed repository, so
  `pacman -Syu` updates the desktop too.
- Publish the app source, signed builds and reproducible packaging; document a second device.
- A migration path between official and prebuilt runtimes, and a rollback to the previous rootfs.
- Structured bridges: call `WifiManager`/`BluetoothAdapter` from the host and expose a small typed
  interface to the guest, instead of maintaining D-Bus mocks.

**Long term — the shape of the thing**

- A real init inside the guest (runit/s6 style) so services are declared, not hand-supervised.
- Zero-copy presentation: dmabuf straight into the Android compositor, frame pacing tied to the
  panel's vsync.
- Support for external displays, hardware keyboards and trackpads as first-class inputs.
- A path to proper isolation (containers or a VM) where the platform allows it, with PRoot as the
  universal fallback.

## Repository layout

```
.
├── README.md                    this file
├── README.zh-CN.md             Chinese translation
├── linuxfs-arch-official.json  default catalog (official tarball + provision)
├── linuxfs-arch.json           fallback catalog (prebuilt runtime)
├── docs/
│   ├── rendering.md            graphics pipeline, kopper, GPU verification
│   ├── runtime-layout.md       where files live, session start order
│   └── publishing.md           packaging, releases, rollback
└── CHANGELOG.md
```

This repository holds artifacts and manifests, not application source. The app, the native
compositor and the packaging scripts live in the app repository (`linuxdesk/`), including
`tools/package-linuxfs.sh` and `tools/provision/`.

## License

The runtime contains software from Arch Linux ARM and its upstream projects; each package keeps its
own license. The scripts, catalogs and documentation in this repository are intended to be released
under the MIT license — the formal `LICENSE` file is still pending, so treat this paragraph as the
intent rather than the instrument.