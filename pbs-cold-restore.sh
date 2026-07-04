#!/bin/bash
set -euo pipefail

# ======= 配置区 =======
S3_BUCKET="baidu-pbs"
S3_PREFIX="pbs-cold-backup"
S3_ENDPOINT="https://s3.openlist.example.com"
PASSPHRASE_FILE="/etc/pbs-cold-backup/passphrase"
DEST_ZVOL="tank/pbs-restore"
# =======================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

# 列出 S3 上的所有全量链文件夹
list_s3_chains() {
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" \
        --endpoint-url="${S3_ENDPOINT}" 2>/dev/null | \
        awk '$0 ~ /\/$/ {print $2}' | sed 's/\/$//' | sort
}

# 列出某个链文件夹里的所有文件
list_chain_files() {
    local chain="$1"
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${chain}/" \
        --endpoint-url="${S3_ENDPOINT}" 2>/dev/null | awk '{print $4}'
}

# 从 S3 下载、解密、解压并 zfs receive
receive_from_s3() {
    local key="$1"
    local receive_flags="$2"
    aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${key}" - \
        --endpoint-url="${S3_ENDPOINT}" | \
        gpg --decrypt --passphrase-file "${PASSPHRASE_FILE}" --batch --yes | \
        zstd -d | \
        zfs receive ${receive_flags} "${DEST_ZVOL}"
}

# 获取所有链
ALL_CHAINS=$(list_s3_chains)
if [ -z "$ALL_CHAINS" ]; then
    log "ERROR: no backup chains found in S3"
    exit 1
fi

# 找到最新全量链（包含 full.zfs.zst.gpg 的最新文件夹）
LATEST_CHAIN=""
for chain in $ALL_CHAINS; do
    if list_chain_files "$chain" | grep -q '^full\.zfs\.zst\.gpg$'; then
        LATEST_CHAIN="$chain"
    fi
done

if [ -z "$LATEST_CHAIN" ]; then
    log "ERROR: no full backup found in any S3 chain"
    exit 1
fi

log "Latest full backup chain: ${LATEST_CHAIN}"

# 创建目标 zvol
if ! zfs list "${DEST_ZVOL}" >/dev/null 2>&1; then
    log "Creating destination zvol ${DEST_ZVOL}"
    zfs create -V 1T "${DEST_ZVOL}"
fi

# 接收全量
log "Restoring full backup from chain ${LATEST_CHAIN}"
receive_from_s3 "${LATEST_CHAIN}/full.zfs.zst.gpg" "-F"

# 应用该链内所有增量，按文件名排序
INCREMENTS=$(list_chain_files "${LATEST_CHAIN}" | grep '^inc-.*\.zfs\.zst\.gpg$' | sort)
if [ -n "$INCREMENTS" ]; then
    log "Applying incremental backups from chain ${LATEST_CHAIN}"
    for inc in $INCREMENTS; do
        log "Applying ${inc}"
        receive_from_s3 "${LATEST_CHAIN}/${inc}" ""
    done
fi

log "Restore done: ${DEST_ZVOL}"
log "Next steps: mount ${DEST_ZVOL} as ext4 and use PBS or extract data"
