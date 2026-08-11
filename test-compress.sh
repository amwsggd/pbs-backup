#!/usr/bin/env bash
# test-compress.sh — ZFS 全量+增量备份自验证测试
#
# 覆盖发送、归档、切片、恢复和哈希比对流程
#
# 环境变量(均有默认):
#   WORK=./zfs_test  POOLSZ=512M  CHUNK=20m  PASS='zfs-test-pass'
#   SEVENZ=7zz  DS=<compress-output.sh路径>  SR=<compress-restore.sh路径>  KEEP=0
set -euo pipefail

WORK="${WORK:-./zfs_test}"; POOLSZ="${POOLSZ:-512M}"; CHUNK="${CHUNK:-20m}"
PASS="${PASS:-zfs-test-pass}"; SEVENZ="${SEVENZ:-7zz}"; KEEP="${KEEP:-0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DS="${DS:-$HERE/compress-output.sh}"; SR="${SR:-$HERE/compress-restore.sh}"
SIMULATE=0; [ "${1:-}" = "--simulate" ] && SIMULATE=1

command -v "$SEVENZ" >/dev/null 2>&1 || { echo "错误: 需要 7-Zip(SEVENZ 指定)" >&2; exit 1; }
[ -x "$DS" ] || chmod +x "$DS" 2>/dev/null || true
[ -x "$SR" ] || chmod +x "$SR" 2>/dev/null || true
rm -rf "$WORK"; mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)

fail() { echo "❌ $1" >&2; exit 1; }

# 管道:数据流 → 归档 → 切片(模拟上传落盘)
backup_pipe() { # $1=fmt $2=目标分片目录
  mkdir -p "$2"
  SEVENZ="$SEVENZ" bash "$DS" -f "$1" -p "$PASS" 2>"$2.pack.log" | split -b "$CHUNK" -d -a 4 - "$2/c_"
}
# 管道: 分片目录 → 恢复 → 下游命令
restore_pipe() { # $1=分片目录 $2=下游命令
  SEVENZ="$SEVENZ" bash "$SR" -d "$1" -p "$PASS" -x "$2" 2>&1 | grep -E '^\[' >&2
}

# ============ 模拟模式:不依赖 ZFS,验证全量+增量管道接线 ============
if [ "$SIMULATE" -eq 1 ]; then
  echo "== SIMULATE:验证归档/切分/恢复的全量+增量接线(无 ZFS) =="
  head -c 20M /dev/urandom > "$WORK/full.stream"
  head -c 3M  /dev/urandom > "$WORK/inc1.stream"
  head -c 2M  /dev/urandom > "$WORK/inc2.stream"
  cat "$WORK/full.stream" | backup_pipe 7z  "$WORK/up_full"
  cat "$WORK/inc1.stream" | backup_pipe 7z  "$WORK/up_inc1"
  cat "$WORK/inc2.stream" | backup_pipe zip "$WORK/up_inc2"   # 增量2走 zip,覆盖双格式
  echo "  全量分片: $(ls "$WORK"/up_full/c_* | wc -l) 片($(head -c4 "$WORK"/up_full/c_0000 | xxd -p | cut -c1-8))"
  echo "  增量1分片: $(ls "$WORK"/up_inc1/c_* | wc -l) 片;  增量2分片: $(ls "$WORK"/up_inc2/c_* | wc -l) 片(PK头=$(head -c4 "$WORK"/up_inc2/c_0000 | xxd -p | cut -c1-8))"
  # 模拟 receive:全量落盘、增量追加
  restore_pipe "$WORK/up_full" "cat > '$WORK/recv.bin'"
  restore_pipe "$WORK/up_inc1" "cat >> '$WORK/recv.bin'"
  restore_pipe "$WORK/up_inc2" "cat >> '$WORK/recv.bin'"
  expect=$(cat "$WORK/full.stream" "$WORK/inc1.stream" "$WORK/inc2.stream" | sha256sum | cut -d' ' -f1)
  actual=$(sha256sum "$WORK/recv.bin" | cut -d' ' -f1)
  echo "  期望(full+inc1+inc2): $expect"
  echo "  实际(恢复拼接)      : $actual"
  [ "$expect" = "$actual" ] && echo "✅ SIMULATE PASS" || fail "SIMULATE FAIL"
  [ "$KEEP" -eq 1 ] || rm -rf "$WORK"
  exit 0
fi

# ============ 真实 ZFS 模式 ============
[ "$(id -u)" -eq 0 ] || fail "真实模式需要 root(sudo 运行)"
command -v zpool >/dev/null 2>&1 || fail "需要 zfsutils(zpool/zfs)"
POOL_A=zfssrc; POOL_B=zfsdst
cleanup() {
  [ "$KEEP" -eq 1 ] && return 0
  zpool destroy "$POOL_A" >/dev/null 2>&1 || true
  zpool destroy "$POOL_B" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
zpool list "$POOL_A" >/dev/null 2>&1 && fail "pool $POOL_A 已存在,先 zpool destroy"
zpool list "$POOL_B" >/dev/null 2>&1 && fail "pool $POOL_B 已存在"

echo "== 1. 创建 img 虚拟磁盘 + ZFS pool =="
truncate -s "$POOLSZ" "$WORK/poolA.img"
zpool create -O mountpoint="$WORK/mntA" "$POOL_A" "$WORK/poolA.img"
zfs set compression=off "$POOL_A"   # 关掉压缩,保证 send 流大小可预期

echo "== 2. 写入随机文件并打快照 =="
mkdir -p "$WORK/mntA/sub/deep"
for i in 1 2 3 4 5; do head -c $((3+RANDOM%5))M /dev/urandom > "$WORK/mntA/file$i.bin"; done
head -c 2M /dev/urandom > "$WORK/mntA/sub/deep/nested.bin"
sync; zfs snapshot "$POOL_A"@s1
echo "  @s1: $(find "$WORK/mntA" -type f | wc -l) 个文件"

head -c 1M /dev/urandom >> "$WORK/mntA/file1.bin"                       # 追加改 file1
dd if=/dev/urandom of="$WORK/mntA/file3.bin" bs=1M seek=1 count=1 conv=notrunc 2>/dev/null  # 改 file3 中间
rm "$WORK/mntA/file2.bin"                                               # 删 file2
head -c 4M /dev/urandom > "$WORK/mntA/file6.bin"                        # 新增 file6
sync; zfs snapshot "$POOL_A"@s2
echo "  @s2: 改file1/file3,删file2,增file6"

rm "$WORK/mntA/file4.bin"; head -c 512K /dev/urandom > "$WORK/mntA/file7.bin"
head -c 1M /dev/urandom >> "$WORK/mntA/sub/deep/nested.bin"
sync; zfs snapshot "$POOL_A"@s3
echo "  @s3: 删file4,增file7,改nested"

echo "== 3. zfs send → 归档 → 切片(模拟上传) =="
zfs send "$POOL_A"@s1                    | backup_pipe 7z  "$WORK/up_full"
echo "  全量  @s1      → 7z  → $(ls "$WORK"/up_full/c_* | wc -l) 片"
zfs send -i "$POOL_A"@s1 "$POOL_A"@s2    | backup_pipe 7z  "$WORK/up_inc1"
echo "  增量  @s1→@s2  → 7z  → $(ls "$WORK"/up_inc1/c_* | wc -l) 片"
zfs send -i "$POOL_A"@s2 "$POOL_A"@s3    | backup_pipe zip "$WORK/up_inc2"
echo "  增量  @s2→@s3  → zip → $(ls "$WORK"/up_inc2/c_* | wc -l) 片(双格式覆盖)"

echo "== 4. 新 img → 新 pool(异机恢复场景) =="
truncate -s "$POOLSZ" "$WORK/poolB.img"
zpool create -O mountpoint="$WORK/mntBroot" "$POOL_B" "$WORK/poolB.img"

echo "== 5. compress-restore → zfs receive 逐级恢复 =="
restore_pipe "$WORK/up_full" "zfs receive -o mountpoint=$WORK/mntB $POOL_B/fsA"
echo "  全量恢复完成: $(zfs list -t snapshot -o name -s name -r $POOL_B | tail -1)"
restore_pipe "$WORK/up_inc1" "zfs receive $POOL_B/fsA"
echo "  增量1恢复完成: $(zfs list -t snapshot -o name -s name -r $POOL_B | tail -1)"
restore_pipe "$WORK/up_inc2" "zfs receive $POOL_B/fsA"
echo "  增量2恢复完成: $(zfs list -t snapshot -o name -s name -r $POOL_B | tail -1)"

echo "== 6. 逐 snapshot 哈希树比对 =="
tree_hash() { (cd "$1" && find . -path ./.zfs -prune -o -type f -exec sha256sum {} + | LC_ALL=C sort | sha256sum | cut -d' ' -f1); }
allpass=1
for s in s1 s2 s3; do
  hA=$(tree_hash "$WORK/mntA/.zfs/snapshot/$s")
  hB=$(tree_hash "$WORK/mntB/.zfs/snapshot/$s")
  if [ "$hA" = "$hB" ]; then echo "  @$s ✅ ($hA)"; else echo "  @$s ❌ A=$hA B=$hB"; allpass=0; fi
done
hA=$(tree_hash "$WORK/mntA"); hB=$(tree_hash "$WORK/mntB")
[ "$hA" = "$hB" ] && echo "  活动树 ✅ ($hA)" || { echo "  活动树 ❌ A=$hA B=$hB"; allpass=0; }
snapN=$(zfs list -t snapshot -o name -s name -r "$POOL_B" | grep -c "fsA@s")
echo "  目标 pool 快照数: $snapN(期望 3)"; [ "$snapN" -eq 3 ] || allpass=0

[ "$allpass" -eq 1 ] && echo "✅ ZFS BACKUP TEST PASS(全量+增量,归档+恢复,哈希一致)" || fail "ZFS BACKUP TEST FAIL"
