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

# 列出 S3 上的所有全量链根目录
list_s3_chains() {
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/" \
        --endpoint-url="${S3_ENDPOINT}" 2>/dev/null | \
        awk '/PRE/{print $2}' | sed 's/\/$//' | sort
}

# 列出某个目录下的所有分片文件
list_parts() {
    local subpath="$1"
    aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${subpath}/" \
        --endpoint-url="${S3_ENDPOINT}" 2>/dev/null | \
        awk '{print $4}' | grep '\.zfs\.zst\.gpg$' | sort
}

# 按顺序下载某个子路径下的所有分片，并合并到 stdout
stream_parts() {
    local subpath="$1"
    local parts
    parts=$(list_parts "$subpath")
    if [ -z "$parts" ]; then
        log "ERROR: no parts found in ${subpath}"
        return 1
    fi
    for part in $parts; do
        log "Downloading ${subpath}/${part}"
        aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/${subpath}/${part}" - \
            --endpoint-url="${S3_ENDPOINT}"
    done
}

# 从 S3 下载分片、解密、解压并 zfs receive
receive_from_s3() {
    local subpath="$1"
    local receive_flags="$2"
    stream_parts "$subpath" | \
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

# 找到最新包含 full/ 目录的链
LATEST_CHAIN=""
for chain in $ALL_CHAINS; do
    if [ -n "$(list_parts "${chain}/full" 2>/dev/null)" ]; then
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
receive_from_s3 "${LATEST_CHAIN}/full" "-F"

# 应用全量链下的所有增量目录
INCREMENTAL_DIRS=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/${LATEST_CHAIN}/" \
    --endpoint-url="${S3_ENDPOINT}" 2>/dev/null | \
    awk '/PRE inc-/{print $2}' | sed 's/\/$//' | sort)

if [ -n "$INCREMENTAL_DIRS" ]; then
    log "Applying incremental backups from chain ${LATEST_CHAIN}"
    for inc_dir in $INCREMENTAL_DIRS; do
        log "Applying ${inc_dir}"
        receive_from_s3 "${LATEST_CHAIN}/${inc_dir}" ""
    done
fi

log "Restore done: ${DEST_ZVOL}"
log "Next steps: mount ${DEST_ZVOL} as ext4 and use PBS or extract data"
