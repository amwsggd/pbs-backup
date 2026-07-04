#!/bin/bash
set -euo pipefail

# ======= 配置区 =======
ZVOL="tank/pbs-datastore"
S3_BUCKET="baidu-pbs"
S3_PREFIX="pbs-cold-backup"
S3_ENDPOINT="https://s3.openlist.example.com"
PASSPHRASE_FILE="/etc/pbs-cold-backup/passphrase"
KEEP_SNAPSHOTS=7
FULL_EVERY=7
KEEP_CHAINS=3
# =======================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# 列出 S3 上的所有备份文件夹（即全量链根目录）
list_s3_chains() {
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" \
        --endpoint-url="${S3_ENDPOINT}" 2>/dev/null | \
        awk '$0 ~ /\/$/ {print $2}' | sed 's/\/$//' | sort
}

# 获取当前最新的全量链文件夹
current_s3_chain() {
    list_s3_chains | tail -n 1
}

# 删除旧的 S3 全量链文件夹，只保留最近的 KEEP_CHAINS 个
cleanup_old_s3_chains() {
    log "Cleaning up old S3 chains, keeping last ${KEEP_CHAINS}"
    local chains
    chains=$(list_s3_chains)
    if [ -z "$chains" ]; then
        return 0
    fi

    echo "$chains" | head -n -${KEEP_CHAINS} | while read -r chain; do
        log "Deleting old S3 chain: ${chain}"
        aws s3 rm "s3://${S3_BUCKET}/${S3_PREFIX}/${chain}/" \
            --recursive \
            --endpoint-url="${S3_ENDPOINT}"
    done
}

# 上传数据流：zfs send → zstd → gpg → aws s3 cp -
upload_stream() {
    local snapshot="$1"
    local prev_snapshot="${2:-}"
    local s3_key="$3"

    if [ -z "$prev_snapshot" ]; then
        # 全量
        zfs send -c "$snapshot"
    else
        # 增量
        zfs send -c -i "$prev_snapshot" "$snapshot"
    fi | zstd -3 | \
        gpg --symmetric --cipher-algo AES256 --compress-algo 0 \
            --passphrase-file "${PASSPHRASE_FILE}" --batch --yes | \
        aws s3 cp - "s3://${S3_BUCKET}/${s3_key}" \
            --endpoint-url="${S3_ENDPOINT}"
}

# 创建本地快照
SNAP_NAME="pbs-$(date +%Y%m%d-%H%M%S)"
SNAPSHOT="${ZVOL}@${SNAP_NAME}"
log "Creating snapshot ${SNAPSHOT}"
zfs snapshot "${SNAPSHOT}"

# 列出所有本地快照
ALL_SNAPS=$(zfs list -t snapshot -H -o name -s creation | grep "^${ZVOL}@pbs-" || true)
SNAP_COUNT=$(echo "$ALL_SNAPS" | grep -c "^${ZVOL}@pbs-" || true)

# 判断全量还是增量
DO_FULL=0
if [ "$SNAP_COUNT" -le 1 ]; then
    DO_FULL=1
elif [ $((SNAP_COUNT % FULL_EVERY)) -eq 0 ]; then
    DO_FULL=1
fi

# 时间戳用于文件夹名和文件名
TIMESTAMP="${SNAP_NAME#pbs-}"

if [ "$DO_FULL" -eq 1 ]; then
    # 新全量：创建新文件夹
    CHAIN_FOLDER="${TIMESTAMP}"
    S3_KEY="${S3_PREFIX}/${CHAIN_FOLDER}/full.zfs.zst.gpg"
    log "Full backup: s3://${S3_BUCKET}/${S3_KEY}"
    upload_stream "${SNAPSHOT}" "" "${S3_KEY}"
else
    # 增量：放入当前最新的全量链文件夹
    CHAIN_FOLDER=$(current_s3_chain)
    if [ -z "$CHAIN_FOLDER" ]; then
        log "ERROR: no existing full backup chain found, cannot do incremental"
        exit 1
    fi
    S3_KEY="${S3_PREFIX}/${CHAIN_FOLDER}/inc-${TIMESTAMP}.zfs.zst.gpg"
    PREV_SNAP=$(echo "$ALL_SNAPS" | tail -n 2 | head -n 1)
    log "Incremental backup: ${PREV_SNAP} -> ${SNAPSHOT} into chain ${CHAIN_FOLDER}"
    upload_stream "${SNAPSHOT}" "${PREV_SNAP}" "${S3_KEY}"
fi

log "Uploaded: s3://${S3_BUCKET}/${S3_KEY}"

# 清理旧的 S3 全量链
cleanup_old_s3_chains

# 清理本地旧快照
log "Cleaning up local snapshots"
echo "$ALL_SNAPS" | head -n -${KEEP_SNAPSHOTS} | xargs -r -n1 zfs destroy

log "Done"
