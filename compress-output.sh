#!/usr/bin/env bash
# compress-output.sh — 将 stdin 封装为 zip/7z 加密归档并输出到 stdout
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  <producer> | compress-output.sh -f zip|7z -p '口令' [选项] > 你的上传管道

选项:
  -f 格式       zip 或 7z(必选)
  -p 口令       必选
  -m 压缩等级   默认 1(流式 zip 不支持 0/store,会自动升为 1;
               流本身已加密/随机时压缩意义不大,1 级开销可忽略)
  -e 条目名     流在包内的文件名,默认 data.bin
               (zip 元数据不加密,名字明文可见,起无害名;7z 用 -mhe=on 连名字都加密)
  -v 分卷大小   仅 7z:默认 200m。7z 无法直接写 stdout(7-Zip 限制),
               实现为:临时目录产出原生分卷(pkg.7z.001...)→ 按序 cat 到 stdout。
               注意:首卷 .001 要等压缩结束才定稿(7-Zip 会回写卷头),
               故 7z 模式无法边产边出,临时占用 = 整个包大小(分卷文件本身可直接当分片用)

环境变量: SEVENZ  默认 7zz

示例:
  tar -cf - /data | compress-output.sh -f 7z -p '口令' | rclone rcat remote:bucket/pkg.7z
  tar -cf - /data | compress-output.sh -f zip -p '口令' | split -b 100m --filter='你的上传器' - p_
USAGE
  exit 1
}

FMT=""; PASS=""; MX="1"; ENTRY="data.bin"; VOL="200m"
while getopts "f:p:m:e:v:" o; do
  case "$o" in
    f) FMT=$OPTARG;; p) PASS=$OPTARG;; m) MX=$OPTARG;;
    e) ENTRY=$OPTARG;; v) VOL=$OPTARG;;
    *) usage;;
  esac
done
[ -n "$FMT" ] && [ -n "$PASS" ] || usage
SEVENZ="${SEVENZ:-7zz}"
command -v "$SEVENZ" >/dev/null 2>&1 || { echo "错误: 找不到 7-Zip,用 SEVENZ 指定" >&2; exit 1; }
[ -t 0 ] && { echo "错误: 需要从管道读数据流" >&2; usage; }

case "$FMT" in
  zip)
    [ "$MX" = "0" ] && { echo "[!] 流式 zip 不支持 store,已自动改为 -m 1" >&2; MX="1"; }
    # ZIP 原生支持流式:零临时文件,直接出字节(进度信息走 stderr,不污染字节流)
    exec "$SEVENZ" a -tzip -so -p"$PASS" -mem=AES256 -mx="$MX" -si"$ENTRY" pkg.zip
    ;;
  7z)
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    # 7z 不支持 -so(实测 E_NOTIMPL):先产出原生分卷临时文件(进度丢弃,错误走 stderr)
    "$SEVENZ" a -t7z -p"$PASS" -mhe=on -mx="$MX" -v"$VOL" -si"$ENTRY" "$TMP/pkg.7z" >/dev/null
    # 分卷数可能超过 999,用数字序拼接,不用 glob(字典序会乱)
    N=$(ls "$TMP"/pkg.7z.* | wc -l)
    for i in $(seq 1 "$N"); do cat "$(printf '%s/pkg.7z.%03d' "$TMP" "$i")"; done
    ;;
  *) usage;;
esac
