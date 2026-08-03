#!/usr/bin/env bash
# compress-restore.sh — 拼接并恢复 compress-output.sh 生成的归档流
set -euo pipefail

usage() {
  cat <<'USAGE'
用法:
  compress-restore.sh -d <分片目录> -p <口令> [选项]   # 分片按文件名自然序(ls -v)拼接
  compress-restore.sh -f <完整包文件> -p <口令> [选项]  # 已经合并好的 zip/7z

选项:
  -m manifest.tsv  可选,先校验再拼。兼容两种格式(取第1列=文件名,最后一列=该分片sha256):
                   shard 模式(3列) / spool 模式(4列) 均可
  -o 解出目录      默认 ./recovered
  -x 下游命令      包内单条目不落盘,直接管道给下游,例:
                   -x 'tar -x -C ./out'      (载荷是 tar)
                   -x 'zstd -d | tar -x -C ./out'
  -k               保留拼接出的完整包(默认用完即删)

环境变量: SEVENZ  默认 7zz
说明:
  - 分片只是字节切片时(上传侧自己切的),拼接后即为完整 zip/7z,魔数自动识别;
  - 若目录里是 7z 原生分卷(pkg.7z.001...),同样适用(拼接=完包),也可直接 7zz x pkg.7z.001;
  - 流式(-si)打出的条目无权限位,解出后自动补 u+rw。
USAGE
  exit 1
}

DIR=""; FILE=""; PASS=""; MANIFEST=""; OUT="./recovered"; DOWNSTREAM=""; KEEP=0
while getopts "d:f:p:m:o:x:k" o; do
  case "$o" in
    d) DIR=$OPTARG;; f) FILE=$OPTARG;; p) PASS=$OPTARG;; m) MANIFEST=$OPTARG;;
    o) OUT=$OPTARG;; x) DOWNSTREAM=$OPTARG;; k) KEEP=1;;
    *) usage;;
  esac
done
[ -n "$PASS" ] && { [ -n "$DIR" ] || [ -n "$FILE" ]; } || usage
SEVENZ="${SEVENZ:-7zz}"

MERGED=""
cleanup() { [ -n "$MERGED" ] && [ "$KEEP" -eq 0 ] && rm -f "$MERGED"; }
trap cleanup EXIT

if [ -n "$FILE" ]; then
  MERGED="$FILE"; KEEP=1   # 用户给的完整包,不删
else
  # 1. 收集分片顺序:manifest 优先,否则目录内自然序
  if [ -n "$MANIFEST" ]; then
    mapfile -t parts < <(awk -F'\t' '{print $1}' "$MANIFEST")
    echo "[1/3] 按 manifest 校验 ${#parts[@]} 个分片…"
    fail=0
    while IFS=$'\t' read -r -a cols; do
      name="${cols[0]}"; sha="${cols[-1]}"; f="$DIR/$name"
      [ -f "$f" ] || { echo "  缺失: $name" >&2; fail=1; continue; }
      [ "$(sha256sum "$f" | cut -d' ' -f1)" = "$sha" ] || { echo "  损坏: $name(重传该片)" >&2; fail=1; }
    done < "$MANIFEST"
    [ "$fail" -eq 0 ] || exit 1
    echo "  校验通过"
  else
    mapfile -t parts < <(ls -v "$DIR")
    echo "[1/3] 无 manifest,按文件名自然序拼接 ${#parts[@]} 个分片(sha 未校验)…"
  fi
  MERGED=$(mktemp --suffix=.merged)
  : > "$MERGED"
  for p in "${parts[@]}"; do cat "$DIR/$p" >> "$MERGED"; done
fi

# 2. 魔数识别(仅展示,7zz 两种都能开)
magic=$(head -c 4 "$MERGED" | xxd -p)
case "$magic" in
  504b0304) kind="ZIP";; 377abcaf) kind="7z";;
  *) kind="未知($magic),仍尝试按压缩包解";;
esac
echo "[2/3] 识别为 $kind 包,总大小 $(stat -c%s "$MERGED") 字节"

# 3. 解密解压
if [ -n "$DOWNSTREAM" ]; then
  echo "[3/3] 流式解出单条目 → 下游: $DOWNSTREAM"
  "$SEVENZ" x -so -p"$PASS" "$MERGED" | eval "$DOWNSTREAM"
else
  echo "[3/3] 解压到 $OUT …"
  mkdir -p "$OUT"
  "$SEVENZ" x -y -p"$PASS" -o"$OUT" "$MERGED"
  find "$OUT" -type f ! -perm -u+r -exec chmod u+rw {} + 2>/dev/null || true  # -si 条目权限修正
fi
echo "[*] 恢复完成"
