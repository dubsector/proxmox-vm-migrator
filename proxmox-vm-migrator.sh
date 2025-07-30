#!/bin/bash
# proxmox-vm-migrator.sh
# Copyright 2025 Jason Houk
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

VERSION="1.1.1"
GITHUB_REPO="dubsector/proxmox-vm-migrator"
SCRIPT_NAME="proxmox-vm-migrator.sh"

# ------------ CONFIGURATION ------------
CONFIG_FILE="$HOME/.proxmox_vm_migrator.conf"
# DUMP_PATH is determined dynamically from selected source storage (path + /dump)
DUMP_PATH=""
REMOTE_DUMP_PATH=""   # determined dynamically from selected target storage (path + /dump)
SSH_USER="root"
CLEANUP=false  # Set to true to delete local backup files after transfer
LOGFILE="$HOME/proxmox_vm_migration_$(date +%F_%H-%M-%S).log"
SHUTDOWN_TIMEOUT=60  # seconds
MIN_FREE_GB=20       # Minimum GB required to proceed
# ---------------------------------------

# ------------ LOGGING SETUP ------------
exec > >(tee -a "$LOGFILE") 2>&1

# ------------ CHECK FOR UPDATES --------
check_for_update() {
    echo "🔍 Checking for updates..."

    LATEST_VERSION=$(curl -s "https://api.github.com/repos/$GITHUB_REPO/releases/latest" | grep '"tag_name":' | cut -d'"' -f4)
    if [ -z "$LATEST_VERSION" ]; then
        echo "⚠️  Could not retrieve latest version from GitHub."
        return
    fi

    LATEST_VERSION_CLEAN="${LATEST_VERSION#v}"

    if [[ "$LATEST_VERSION_CLEAN" != "$VERSION" ]]; then
        echo "🚀 New version available: $LATEST_VERSION_CLEAN (current: $VERSION)"
        read -p "🔄 Do you want to update and restart now? [y/N]: " DO_UPDATE
        if [[ "$DO_UPDATE" =~ ^[Yy]$ ]]; then
            TMP_SCRIPT="/tmp/$SCRIPT_NAME"
            echo "⬇️  Downloading latest version from GitHub..."
            curl -s -L "https://raw.githubusercontent.com/$GITHUB_REPO/main/$SCRIPT_NAME" -o "$TMP_SCRIPT"
            if [ -s "$TMP_SCRIPT" ]; then
                chmod +x "$TMP_SCRIPT"
                mv "$TMP_SCRIPT" "$0"
                echo "✅ Updated to version $LATEST_VERSION_CLEAN"
                echo "🔁 Restarting script..."
                exec "$0" "$@"
            else
                echo "❌ Failed to download the updated script."
                exit 1
            fi
        else
            echo "⏭️  Update skipped by user."
        fi
    else
        echo "✅ You are running the latest version ($VERSION)."
    fi
}
check_for_update "$@"

# ------------ TOOL CHECKS --------------
echo "🔍 Performing pre-flight checks..."
for cmd in vzdump rsync ssh qm pvesm awk sed grep; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Required tool '$cmd' is not installed. Aborting."
        exit 1
    fi
done

# ------------ SIMPLE CONFIG KV ----------
cfg_load() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
}

cfg_set() {
  local key="$1"; shift
  local val="$*"
  touch "$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE"
  if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s#^${key}=.*#${key}=${val}#g" "$CONFIG_FILE"
  else
    echo "${key}=${val}" >> "$CONFIG_FILE"
  fi
}

cfg_load

# ------------ TARGET HOST SETUP --------
if [[ -n "$LAST_TARGET" ]]; then
  echo "📁 Last target host: $LAST_TARGET"
else
  echo "📁 Last target host: (none)"
fi

read -p "🖥️ Enter target Proxmox host IP or hostname [${LAST_TARGET:-}]: " TARGET_HOST
TARGET_HOST="${TARGET_HOST:-$LAST_TARGET}"

if [ -z "$TARGET_HOST" ]; then
    echo "❌ No target host provided. Aborting."
    exit 1
fi
cfg_set LAST_TARGET "$TARGET_HOST"

# ------------ STORAGE HELPERS (LOCAL) ---
# path of a dir storage on local node
cfg_get_dir_path_local() {
  local store="$1"
  awk -v s="$store" '
    BEGIN{RS=""; FS="\n"}
    $0 ~ "^dir: " s "([[:space:]]|$)" {
      for (i=1;i<=NF;i++) if ($i ~ /^[[:space:]]*path[[:space:]]+/) {
        split($i,a,/[[:space:]]+/); print a[2]; exit
      }
    }' /etc/pve/storage.cfg
}

# does a local storage declare content=...backup... ?
cfg_storage_has_backup_local() {
  local store="$1"
  awk -v s="$store" '
    BEGIN{RS=""; FS="\n"}
    $0 ~ "^dir: " s "([[:space:]]|$)" {
      for (i=1;i<=NF;i++) if ($i ~ /^[[:space:]]*content[[:space:]]+/) {
        if ($i ~ /backup/) { print "yes"; exit }
      }
    }' /etc/pve/storage.cfg
}

# list eligible local dir storages that support backup and are active
list_dir_backup_storages_local() {
  local ids
  ids=$(awk '
    BEGIN{RS=""; FS="\n"}
    /^dir: / { split($1,a,":"); gsub(/^dir:[[:space:]]*/,"",a[0]); store=a[0];
      hasbackup=0; for (i=1;i<=NF;i++) if ($i ~ /^[[:space:]]*content[[:space:]]+/ && $i ~ /backup/){hasbackup=1}
      if(hasbackup){print store}
    }' /etc/pve/storage.cfg)

  # keep only active storages
  while read -r s; do
    [[ -z "$s" ]] && continue
    if pvesm status | awk '{print $1,$2}' | grep -q "^${s} active$"; then
      echo "$s"
    fi
  done <<< "$ids"
}

# free GB for local storage from pvesm status (avail in KiB -> GB)
free_gb_local() {
  local store="$1"
  local kb
  kb=$(pvesm status | awk -v s="$store" '$1==s {print $4}')
  [[ -z "$kb" ]] && echo 0 && return
  echo $(( kb / 1024 / 1024 ))
}

# ------------ STORAGE HELPERS (REMOTE) --
cfg_get_dir_path_remote() {
  local host="$1" store="$2"
  ssh -o BatchMode=yes "$SSH_USER@$host" \
    "awk -v s='$store' 'BEGIN{RS=\"\";FS=\"\\n\"} \$0 ~ \"^dir: \" s \"([[:space:]]|$)\" { for(i=1;i<=NF;i++) if (\$i ~ /^[[:space:]]*path[[:space:]]+/){ split(\$i,a,/[^[:space:]]+[[:space:]]+/); print a[2]; exit } }' /etc/pve/storage.cfg"
}

cfg_storage_has_backup_remote() {
  local host="$1" store="$2"
  ssh -o BatchMode=yes "$SSH_USER@$host" \
    "awk -v s='$store' 'BEGIN{RS=\"\";FS=\"\\n\"} \$0 ~ \"^dir: \" s \"([[:space:]]|$)\" { for(i=1;i<=NF;i++) if (\$i ~ /^[[:space:]]*content[[:space:]]+/ && \$i ~ /backup/){ print \"yes\"; exit } }' /etc/pve/storage.cfg"
}

list_dir_backup_storages_remote() {
  local host="$1"
  local ids
  ids=$(ssh -o BatchMode=yes "$SSH_USER@$host" \
    "awk 'BEGIN{RS=\"\";FS=\"\\n\"} /^dir: / { split(\$1,a,\":\"); gsub(/^dir:[[:space:]]*/,\"\",a[0]); store=a[0]; hasbackup=0; for(i=1;i<=NF;i++) if (\$i ~ /^[[:space:]]*content[[:space:]]+/ && \$i ~ /backup/){hasbackup=1} if(hasbackup){print store}}' /etc/pve/storage.cfg")

  # keep only active
  while read -r s; do
    [[ -z "$s" ]] && continue
    if ssh -o BatchMode=yes "$SSH_USER@$host" "pvesm status | awk '{print \$1,\$2}' | grep -q '^${s} active\$'"; then
      echo "$s"
    fi
  done <<< "$ids"
}

free_gb_remote() {
  local host="$1" store="$2"
  local kb
  kb=$(ssh -o BatchMode=yes "$SSH_USER@$host" "pvesm status | awk -v s='$store' '\$1==s {print \$4}'")
  [[ -z "$kb" ]] && echo 0 && return
  echo $(( kb / 1024 / 1024 ))
}

# ------------ SELECT SOURCE STORAGE -----
select_source_storage() {
  local eligible=() labels=() idx=1 choice sel store free path
  local last="${LAST_SOURCE_STORE:-}"

  while read -r s; do
    [[ -z "$s" ]] && continue
    # ensure backup content + path exists
    [[ -z "$(cfg_storage_has_backup_local "$s")" ]] && continue
    path="$(cfg_get_dir_path_local "$s")"
    [[ -z "$path" ]] && continue
    free="$(free_gb_local "$s")"
    if (( free >= MIN_FREE_GB )); then
      eligible+=("$s")
      labels+=("$idx) $s  —  free: ${free} GB  (path: $path)")
      ((idx++))
    fi
  done < <(list_dir_backup_storages_local)

  if ((${#eligible[@]}==0)); then
    echo "❌ No eligible local directory storage with ≥ ${MIN_FREE_GB} GB free. Aborting."
    exit 1
  fi

  # auto-select last if still eligible
  if [[ -n "$last" ]]; then
    for s in "${eligible[@]}"; do
      if [[ "$s" == "$last" ]]; then
        echo "✅ Using last source storage: $s"
        echo "$s"
        return 0
      fi
    done
  fi

  echo "📂 Select SOURCE storage for backups:"
  printf '%s\n' "${labels[@]}"
  read -p "Enter number [1-${#eligible[@]}]: " choice
  sel=$((choice-1))
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#eligible[@]} )); then
    echo "❌ Invalid selection."
    exit 1
  fi
  store="${eligible[$sel]}"
  echo "$store"
}

# ------------ SELECT TARGET STORAGE -----
select_target_storage() {
  local host="$1"
  local eligible=() labels=() idx=1 choice sel store free path
  local last="${LAST_TARGET_STORE:-}"

  while read -r s; do
    [[ -z "$s" ]] && continue
    [[ -z "$(cfg_storage_has_backup_remote "$host" "$s")" ]] && continue
    path="$(cfg_get_dir_path_remote "$host" "$s")"
    [[ -z "$path" ]] && continue
    free="$(free_gb_remote "$host" "$s")"
    if (( free >= MIN_FREE_GB )); then
      eligible+=("$s")
      labels+=("$idx) $s  —  free: ${free} GB  (remote path: $path)")
      ((idx++))
    fi
  done < <(list_dir_backup_storages_remote "$host")

  if ((${#eligible[@]}==0)); then
    echo "❌ No eligible TARGET directory storage with ≥ ${MIN_FREE_GB} GB free on $host. Aborting."
    exit 1
  fi

  # auto-select last if still eligible
  if [[ -n "$last" ]]; then
    for s in "${eligible[@]}"; do
      if [[ "$s" == "$last" ]]; then
        echo "✅ Using last target storage: $s"
        echo "$s"
        return 0
      fi
    done
  fi

  echo "📦 Select TARGET storage to receive backups on $host:"
  printf '%s\n' "${labels[@]}"
  read -p "Enter number [1-${#eligible[@]}]: " choice
  sel=$((choice-1))
  if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#eligible[@]} )); then
    echo "❌ Invalid selection."
    exit 1
  fi
  store="${eligible[$sel]}"
  echo "$store"
}

# ------------ VM INPUT -----------------
echo ""
echo "💡 Enter VMIDs to migrate using spaces."
echo "   - Use single IDs:  101 110"
echo "   - Use ranges:      103-105"
echo "   ❗ Do NOT use commas."
read -p "🔢 Enter VMIDs to migrate: " -a RAW_VMS

# ------------ EXPAND VMIDS -------------
expand_vmids() {
    local raw_input=("$@")
    local expanded=()
    for token in "${raw_input[@]}"; do
        if [[ "$token" =~ ^[0-9]+$ ]]; then
            expanded+=("$token")
        elif [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            if ((start > end)); then
                echo "❌ Invalid range: $token"
                exit 1
            fi
            for ((i=start; i<=end; i++)); do
                expanded+=("$i")
            done
        else
            echo "❌ Invalid VMID format: '$token'"
            exit 1
        fi
    done
    echo "${expanded[@]}"
}

VM_IDS=($(expand_vmids "${RAW_VMS[@]}"))

if [ ${#VM_IDS[@]} -eq 0 ]; then
    echo "❌ No valid VMIDs found. Aborting."
    exit 1
fi

# ------------ SELECT STORAGES ----------
SOURCE_STORE="$(select_source_storage)"
SOURCE_PATH="$(cfg_get_dir_path_local "$SOURCE_STORE")"
DUMP_PATH="$SOURCE_PATH/dump"

TARGET_STORE="$(select_target_storage "$TARGET_HOST")"
TARGET_PATH="$(cfg_get_dir_path_remote "$TARGET_HOST" "$TARGET_STORE")"
REMOTE_DUMP_PATH="$TARGET_PATH/dump"

echo "🔎 Validating free space ≥ ${MIN_FREE_GB} GB..."
SRC_FREE="$(free_gb_local "$SOURCE_STORE")"
DST_FREE="$(free_gb_remote "$TARGET_HOST" "$TARGET_STORE")"
echo "   • Source: $SOURCE_STORE  — free ${SRC_FREE} GB (path: $SOURCE_PATH)"
echo "   • Target: $TARGET_STORE  — free ${DST_FREE} GB (path: $TARGET_PATH)"

# persist last choices
cfg_set LAST_SOURCE_STORE "$SOURCE_STORE"
cfg_set LAST_TARGET_STORE "$TARGET_STORE"

# ensure remote dump dir exists
ssh "$SSH_USER@$TARGET_HOST" "mkdir -p '$REMOTE_DUMP_PATH'" || {
    echo "❌ Failed to ensure remote directory exists: $REMOTE_DUMP_PATH"
    exit 1
}

# ------------ CONFIRM ------------------
echo ""
echo "✅ Target Host: $TARGET_HOST"
echo "✅ VMIDs to migrate: ${VM_IDS[*]}"
echo "✅ Source backup storage: $SOURCE_STORE  ($SOURCE_PATH)"
echo "✅ Target backup storage: $TARGET_STORE  ($TARGET_PATH)"
read -p "⚠️  Proceed with backup and transfer? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "🛑 Aborted by user."
    exit 0
fi

# ------------ MIGRATION PROCESS --------
TOTAL_START=$(date +%s)
SUCCESSFUL_IDS=()
FAILED_IDS=()

for VMID in "${VM_IDS[@]}"; do
    echo ""
    echo "🔄 Processing VM $VMID..."
    START_VM_TIME=$(date +%s)

    VM_STATUS=$(qm status $VMID | awk '{print $2}')
    if [ "$VM_STATUS" == "running" ]; then
        echo "⚠️  VM $VMID is running — attempting shutdown..."
        qm shutdown $VMID

        echo "⏳ Waiting for VM $VMID to shut down (timeout: ${SHUTDOWN_TIMEOUT}s)..."
        WAIT_TIME=0
        while [ "$WAIT_TIME" -lt "$SHUTDOWN_TIMEOUT" ]; do
            sleep 5
            VM_STATUS=$(qm status $VMID | awk '{print $2}')
            if [ "$VM_STATUS" == "stopped" ]; then
                echo "✅ VM $VMID successfully powered off."
                break
            fi
            WAIT_TIME=$((WAIT_TIME + 5))
        done

        if [ "$VM_STATUS" != "stopped" ]; then
            echo "❌ VM $VMID did not shut down in time. Skipping."
            FAILED_IDS+=("$VMID")
            continue
        fi
    else
        echo "✅ VM $VMID is already stopped."
    fi

    echo "💾 Backing up VM $VMID to storage '$SOURCE_STORE'..."
    # Use storage ID so vzdump uses storage's dump dir automatically
    if ! vzdump "$VMID" --compress zstd --storage "$SOURCE_STORE"; then
        echo "❌ vzdump failed for VM $VMID."
        FAILED_IDS+=("$VMID")
        continue
    fi

    BACKUP_FILE=$(ls -t "$DUMP_PATH"/vzdump-qemu-${VMID}-*.zst 2>/dev/null | head -n 1)
    if [ ! -f "$BACKUP_FILE" ]; then
        echo "❌ Backup for VM $VMID not found in $DUMP_PATH. Skipping."
        FAILED_IDS+=("$VMID")
        continue
    fi

    echo "📤 Transferring $(basename "$BACKUP_FILE") to $TARGET_HOST:$REMOTE_DUMP_PATH with progress..."
    if ! rsync -ah --progress "$BACKUP_FILE" "$SSH_USER@$TARGET_HOST:$REMOTE_DUMP_PATH/"; then
        echo "❌ Transfer failed for VM $VMID."
        FAILED_IDS+=("$VMID")
        continue
    fi

    if $CLEANUP; then
        echo "🧹 Cleaning up local backup: $BACKUP_FILE"
        rm -f "$BACKUP_FILE"
    fi

    END_VM_TIME=$(date +%s)
    DURATION=$((END_VM_TIME - START_VM_TIME))
    echo "✅ VM $VMID migrated in $((DURATION / 60))m $((DURATION % 60))s"
    SUCCESSFUL_IDS+=("$VMID")
done

# ------------ WRAP-UP ------------------
TOTAL_END=$(date +%s)
TOTAL_TIME=$((TOTAL_END - TOTAL_START))

echo ""
echo "🎉 Migration Complete!"
echo "🕒 Total time: $((TOTAL_TIME / 60)) minutes and $((TOTAL_TIME % 60)) seconds"
echo ""
echo "📋 Summary Report:"
if [ ${#SUCCESSFUL_IDS[@]} -gt 0 ]; then
    echo "✅ Successfully migrated:"
    for ID in "${SUCCESSFUL_IDS[@]}"; do
        echo "   - VM $ID"
    done
fi

if [ ${#FAILED_IDS[@]} -gt 0 ]; then
    echo "❌ Failed to migrate:"
    for ID in "${FAILED_IDS[@]}"; do
        echo "   - VM $ID"
    done
fi

echo ""
echo "📂 Restore your VMs at https://$TARGET_HOST:8006 → 'local' → 'Backups'."
echo "📝 Log saved to: $LOGFILE"
