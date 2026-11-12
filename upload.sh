#!/bin/sh
# 建仓库 + 传 rootfs + 发 release + 回写 catalog 地址。
#
#   GH_TOKEN=ghp_xxx OWNER=MarkisLin REPO=linuxdesk-components ./upload.sh
#
# 需要：curl。tar 包默认在 ../linuxfs-arch-2026.11.tar.zst，大小 1.76 GB。
set -eu

: "${GH_TOKEN:?need GH_TOKEN (a GitHub PAT with repo scope)}"
: "${OWNER:-MarkisLin}"
REPO="${REPO:-linuxdesk-components}"
HERE=$(cd "$(dirname "$0")" && pwd)
TAR="${TAR:-$HERE/../linuxfs-arch-2026.11.tar.zst}"
TAG="${TAG:-linuxfs-2026.11}"
NAME="linuxfs-arch-2026.11.tar.zst"

[ -f "$TAR" ] || { echo "missing $TAR" >&2; exit 1; }
API="https://api.github.com"
AUTH="Authorization: Bearer $GH_TOKEN"
JSON="Accept: application/vnd.github+json"

echo "== 1/4 创建仓库 $OWNER/$REPO"
code=$(curl -sS --ssl-no-revoke -o /tmp/repo.json -w '%{http_code}' -X POST "$API/user/repos" \
  -H "$AUTH" -H "$JSON" \
  -d "{\"name\":\"$REPO\",\"description\":\"Prebuilt Arch Linux ARM desktop runtime for LinuxDesk (niri + DMS + Mesa kopper)\",\"private\":false,\"has_issues\":true}")
if [ "$code" = "201" ]; then
  echo "   created"
elif [ "$code" = "422" ]; then
  echo "   已存在，继续"
else
  echo "   失败 HTTP $code:" >&2; cat /tmp/repo.json >&2; exit 1
fi

echo "== 2/4 创建 release $TAG"
curl -sS --ssl-no-revoke -X POST "$API/repos/$OWNER/$REPO/releases" \
  -H "$AUTH" -H "$JSON" \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"Arch desktop runtime $TAG\",\"body\":\"rootfs 2026.11：niri + DMS + Mesa kopper + Venus + nm/bluez 桥接。\"}" \
  -o /tmp/rel.json
python3 - <<'PY' > /tmp/upurl
import json
d = json.load(open('/tmp/rel.json'))
print(d.get('upload_url', '').split('{')[0])
PY
UP=$(cat /tmp/upurl)
[ -n "$UP" ] || { echo "no upload_url:" >&2; cat /tmp/rel.json >&2; exit 1; }
echo "   $UP"

echo "== 3/4 上传 $NAME ($(stat -c %s "$TAR" 2>/dev/null || wc -c < "$TAR") bytes)"
curl -sS --ssl-no-revoke -X POST "$UP?name=$NAME" \
  -H "$AUTH" -H "Content-Type: application/octet-stream" \
  --data-binary "@$TAR" -o /tmp/asset.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/asset.json'))
print('   asset:', d.get('name'), d.get('size'), d.get('state') or d.get('message'))
PY

echo "== 4/4 生成 catalog 与更新 App 默认地址"
SHA=$(python3 - "$TAR" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], 'rb') as f:
    for b in iter(lambda: f.read(1 << 20), b''):
        h.update(b)
print(h.hexdigest())
PY
)
SIZE=$(wc -c < "$TAR" | tr -d ' ')
cat > "$HERE/linuxfs-arch.json" <<JSON
{"version":"2026.11","url":"https://github.com/$OWNER/$REPO/releases/download/$TAG/$NAME","sha256":"$SHA","size":$SIZE}
JSON
echo "   catalog: $HERE/linuxfs-arch.json"
echo "   sha256:  $SHA"
echo
echo "下一步：把下面这行填进 linuxdesk/app/build.gradle 的 LINUXFS_CATALOG 默认值"
echo "https://raw.githubusercontent.com/$OWNER/$REPO/main/linuxfs-arch.json"