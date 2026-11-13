# 发布一个运行时版本

面向维护者。目标是：改完 rootfs → 打包 → 发 Release → 更新 catalog，让已经装了 App 的人拿到新版本。

## 0. 前提

- 打好包的 rootfs 树（例如从平板 `adb exec-out run-as com.dsh.linuxdesk tar ...` 拉回来的那份）
- `zstd`、`curl`（Windows 上用 `C:\Windows\system32\curl.exe`，并加 `--ssl-no-revoke`）
- 一个能发 Release 的 GitHub token（`repo` 权限；只推本仓库时需要 `contents: write`）

## 1. 打包

```bash
tools/package-linuxfs.sh \
  --root /path/to/arch-rootfs \
  --version 2026.12 \
  --out dist/ \
  --base-url https://github.com/MarkisLin/ARCH-DESK/releases/download/linuxfs-2026.12
```

脚本行为：

- 剔除 `/root` `/home` `/proc` `/sys` `/dev` `/run` `/tmp` `/storage` `/mnt` `/media`
  `/lost+found` `/var/log` `/var/cache/pacman/pkg` `/var/tmp` `/.cache`
  —— 注意 `data/` 必须排除，它是 Android 侧的挂载点，不排除会把 `files/linuxfs` 反向包含，
  归档会在一分钟内涨到十几 GB
- `zstd -6 -T0`（没有 zstd 时退化为 gzip）
- 输出 `linuxfs-arch-<version>.tar.zst` 与 `linuxfs-arch.json`

自检产物：

```bash
zstd -t dist/linuxfs-arch-2026.12.tar.zst
tar --zstd -tf dist/linuxfs-arch-2026.12.tar.zst | head
# 应能看到 ./etc/arch-release、./usr/bin/niri、./usr/bin/dms、
# ./usr/local/bin/dd-nmmock、./usr/local/share/droiddeck/AudioService.qml.patched
```

## 2. 发 Release

```bash
TOKEN=...                       # 不要写进脚本、不要提交
REPO=MarkisLin/linuxdesk-components
TAG=linuxfs-2026.12

curl -sS --ssl-no-revoke -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/$REPO/releases \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"linuxfs 2026.12\",\"body\":\"运行时 2026.12\"}"

curl -sS --ssl-no-revoke -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @"dist/linuxfs-arch-2026.12.tar.zst" \
  "https://uploads.github.com/repos/$REPO/releases/<release-id>/assets?name=linuxfs-arch-2026.12.tar.zst"
```

第一次往空仓库发 Release 会得到 `422 Repository is empty.`：先随便推一个 commit 到 `main`。

1.76 GB 的资产上传大约 3 分钟；`GET /releases/<id>/assets` 可确认 `state: uploaded`。

## 3. 更新 catalog

把新的 `linuxfs-arch.json` 覆盖仓库根目录那份，提交即可：

```bash
cp dist/linuxfs-arch.json .
git add linuxfs-arch.json README.md CHANGELOG.md
git commit -m "linuxfs 2026.12"
git push origin main
```

App 只认 `https://raw.githubusercontent.com/MarkisLin/ARCH-DESK/main/linuxfs-arch.json`，
推送后下次启动就会看到新版本。要临时指向别的 catalog，编译时加
`-PdroiddeckCatalog=<url>`（对应 `BuildConfig.LINUXFS_CATALOG`）。

## 4. 回滚

- 不要删老 Release：用户已经下载的版本不依赖 catalog
- catalog 改回上一版的 JSON 并提交，就是一次干净的"撤回发布"
- 如果只是 rootfs 里某个脚本坏了，优先用 App 自检页的"修复"（重新 stage + 重打补丁），
  不必发新版本

## 检查清单

- [ ] `zstd -t` 通过
- [ ] 归档里没有 `./data`、`./proc`、`./root`
- [ ] `sha256` 与 `size` 与文件实际值一致（脚本算的，别手改）
- [ ] Release 资产名与 catalog 的 `url` 完全对应
- [ ] 在设备上冷装一次：清 `files/linuxfs` → 打开 App → 等下载解压 → 自检全绿