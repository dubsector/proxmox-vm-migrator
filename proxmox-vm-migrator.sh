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

VERSION="1.1.3"
GITHUB_REPO="dubsector/proxmox-vm-migrator"
SCRIPT_NAME="proxmox-vm-migrator.sh"

# ------------ CONFIGURATION ------------
CONFIG_FILE="$HOME/.proxmox_vm_migrator.conf"
DUMP_PATH="/var/lib/vz/dump"
REMOTE_DUMP_PATH="/var/lib/vz/dump"
SSH_USER="root"
CLEANUP=false  # Set to true to delete local backup files after transfer
LOGFILE="$HOME/proxmox_vm_migration_$(date +%F_%H-%M-%S).log"
SHUTDOWN_TIMEOUT=60  # seconds
# ---------------------------------------

# ------------ LOGGING SETUP ------------
exec > >(tee -a "$LOGFILE") 2>&1

# ------------ CONFIG / SSH HELPERS (added) ------------
# establish SSH trust (allow password on first run)
ensure_ssh_trust() {
  local host="$1"
  ssh -o StrictHostKeyChecking=accept-new "$SSH_USER@$host" "true" || true
}

# Simple sanitized config loader/saver
cfg_load() {
  [[ -f "$CONFIG_FILE" ]] || return
  local _tmp
  _tmp="$(mktemp)"
  grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$CONFIG_FILE" > "$_tmp" || true
  # shellcheck disable=SC1090
  . "$_tmp"
  rm -f "$_tmp"
}
cfg_set() {
  local key="$1"; shift; local val="$*"
  touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"
  if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
    sed -i "s#^${key}=.*#${key}=${val}#g" "$CONFIG_FILE"
  else
    echo "${key}=${val}" >> "$CONFIG_FILE"
  fi
}
cfg_load

# Storage parsing from /etc/pve/storage.cfg (local) and remote
get_dir_path_local() {
  local store="$1"
  awk -v s="$store" 'BEGIN{RS="";FS="\n"} $0 ~ "^dir: " s "([[:space:]]|$)" {for(i=1;i<=NF;i++) if($i ~ /^[[:space:]]*path[[:space:]]+/){split($i,a,/[[:space:]]+/); print a[2]; exit}}' /etc/pve/storage.cfg
}
get_dir_path_remote() {
  local host="$1" store="$2"
  ssh "$SSH_USER@$host" "awk -v s='$store' 'BEGIN{RS=\"\";FS=\"\\n\"} \$0 ~ \"^dir: \" s \"([[:space:]]|$)\" {for(i=1;i<=NF;i++) if(\$i ~ /^[[:space:]]*path[[:space:]]+/){split(\$i,a,/[^[:space:]]+[[:space:]]+/); print a[2]; exit}}' /etc/pve/storage.cfg"
}
list_dir_backup_local() {
  awk 'BEGIN{RS="";FS="\n"} /^dir: /{split($1,a,\":\"); gsub(/^dir:[ \\t]*/,\"\",a[1]); id=a[1]; has=0; path=\"\"; for(i=1;i<=NF;i++){if($i ~ /^[ \\t]*content[ \\t]+/ && $i ~ /backup/) has=1; if($i ~ /^[ \\t]*path[ \\t]+/){split($i,b,/[ \\t]+/); path=b[2]}} if(has && path!=\"\"){print id\"|\"path}}' /etc/pve/storage.cfg
}
list_dir_backup_remote() {
  local host="$1"
  ssh "$SSH_USER@$host" "awk 'BEGIN{RS=\"\";FS=\"\\n\"} /^dir: /{split(\$1,a,\":\"); gsub(/^dir:[ \\t]*/,\"\",a[1]); id=a[1]; has=0; path=\"\"; for(i=1;i<=NF;i++){if(\$i ~ /^[ \\t]*content[ \\t]+/ && \$i ~ /backup/) has=1; if(\$i ~ /^[ \\t]*path[ \\t]+/){split(\$i,b,/[^[:space:]]+[[:space:]]+/); path=b[2]}} if(has && path!=\"\"){print id\"|\"path}}' /etc/pve/storage.cfg"
}
free_gb_local() { local store="$1"; local kb; kb=$(pvesm status | awk -v s="$store" '$1==s {print $4}'); [[ -z "$kb" ]] && echo 0 || echo $((kb/1024/1024)); }
free_gb_remote() { local host="$1" store="$2"; local kb; kb=$(ssh "$SSH_USER@$host" "pvesm status | awk -v s='$store' '\$1==s {print \$4}'"); [[ -z "$kb" ]] && echo 0 || echo $((kb/1024/1024)); }

select_source_storage() {
  local last="${LAST_SOURCE_STORAGE:-}"; local ids=() paths=() frees=() labels=() i=1
  while IFS='|' read -r id path; do
    [[ -z "$id" || -z "$path" ]] && continue
    pvesm status | awk '{print $1,$2}' | grep -q "^${id} active$" || continue
    local free; free=$(free_gb_local "$id")
    ids+=("$id"); paths+=("$path"); frees+=("$free"); labels+=("$i) $id — free: ${free} GB (path: $path)"); ((i++))
  done < <(list_dir_backup_local)
  (( ${#ids[@]} > 0 )) || { echo "❌ No eligible local directory storage with backup content."; exit 1; }
  if [[ -n "$last" ]]; then
    for j in "${!ids[@]}"; do
      [[ "${ids[$j]}" == "$last" ]] && { echo "✅ Using last source: $last"; SELECTED_SOURCE_STORE="$last"; SELECTED_SOURCE_PATH="${paths[$j]}"; return; }
    done
  fi
  echo "📂 Select SOURCE storage:"; printf '%s\n' "${labels[@]}"; read -p "Enter number [1-${#ids[@]}]: " choice
  local idx=$((choice-1)); [[ $idx -ge 0 && $idx -lt ${#ids[@]} ]] || { echo "❌ Invalid selection."; exit 1; }
  SELECTED_SOURCE_STORE="${ids[$idx]}"; SELECTED_SOURCE_PATH="${paths[$idx]}";
}

select_target_storage() {
  local host="$1"; ensure_ssh_trust "$host"; local last="${LAST_TARGET_STORAGE:-}"; local ids=() paths=() frees=() labels=() i=1
  while IFS='|' read -r id path; do
    [[ -z "$id" || -z "$path" ]] && continue
    ssh "$SSH_USER@$host" "pvesm status | awk '{print \\\$1,\\\$2}' | grep -q '^${id} active\$'" || continue
    local free; free=$(free_gb_remote "$host" "$id")
    ids+=("$id"); paths+=("$path"); frees+=("$free"); labels+=("$i) $id — free: ${free} GB (remote path: $path)"); ((i++))
  done < <(list_dir_backup_remote "$host")
  (( ${#ids[@]} > 0 )) || { echo "❌ No eligible TARGET directory storage with backup content on $host."; exit 1; }
  if [[ -n "$last" ]]; then
    for j in "${!ids[@]}"; do
      [[ "${ids[$j]}" == "$last" ]] && { echo "✅ Using last target: $last"; SELECTED_TARGET_STORE="$last"; SELECTED_TARGET_PATH="${paths[$j]}"; return; }
    done
  fi
  echo "📦 Select TARGET storage on $host:"; printf '%s\n' "${labels[@]}"; read -p "Enter number [1-${#ids[@]}]: " choice
  local idx=$((choice-1)); [[ $idx -ge 0 && $idx -lt ${#ids[@]} ]] || { echo "❌ Invalid selection."; exit 1; }
  SELECTED_TARGET_STORE="${ids[$idx]}"; SELECTED_TARGET_PATH="${paths[$idx]}";
}


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
for cmd in vzdump rsync ssh qm; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "❌ Required tool '$cmd' is not installed. Aborting."
        exit 1
    fi
done


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

# Select storages (origin & target)
select_source_storage
select_target_storage "$TARGET_HOST"
SOURCE_PATH="$SELECTED_SOURCE_PATH"
TARGET_PATH="$SELECTED_TARGET_PATH"
DUMP_PATH="${SOURCE_PATH}/dump"
REMOTE_DUMP_PATH="${TARGET_PATH}/dump"
cfg_set LAST_SOURCE_STORAGE "$SELECTED_SOURCE_STORE"
cfg_set LAST_TARGET_STORAGE "$SELECTED_TARGET_STORE"
ssh "$SSH_USER@$TARGET_HOST" "mkdir -p '$REMOTE_DUMP_PATH'" || { echo "❌ Failed to ensure remote directory exists: $REMOTE_DUMP_PATH"; exit 1; }

echo "🔎 Validating free space ≥ ${MIN_FREE_GB} GB..."
echo "   • Source: ${SELECTED_SOURCE_STORE} — free $(free_gb_local "${SELECTED_SOURCE_STORE}") GB (path: $SOURCE_PATH)"
echo "   • Target: ${SELECTED_TARGET_STORE} — free $(free_gb_remote "$TARGET_HOST" "${SELECTED_TARGET_STORE}") GB (path: $TARGET_PATH)"

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

# ------------ CONFIRM ------------------
echo ""
echo "✅ Target Host: $TARGET_HOST"
echo "✅ VMIDs to migrate: ${VM_IDS[*]}"
echo "✅ Source backup storage: ${SELECTED_SOURCE_STORE}  ($SOURCE_PATH)"
echo "✅ Target backup storage: ${SELECTED_TARGET_STORE}  ($TARGET_PATH)"
echo ""
echo "✅ VMIDs to migrate: ${VM_IDS[*]}"
read -p "⚠️  Proceed with backup and transfer? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "🛑 Aborted by user."
    exit 0
fi

# ------------ REMOTE DIR CHECK ---------
echo "📦 Checking for remote dump directory on $TARGET_HOST..."
ssh "$SSH_USER@$TARGET_HOST" "test -d '$REMOTE_DUMP_PATH' || mkdir -p '$REMOTE_DUMP_PATH'" || {
    echo "❌ Failed to ensure remote directory exists."
    exit 1
}

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

    echo "💾 Backing up VM $VMID..."
    vzdump $VMID --compress zstd --storage "$SELECTED_SOURCE_STORE"
    BACKUP_FILE=$(ls -t "$DUMP_PATH"/vzdump-qemu-${VMID}-*.zst 2>/dev/null | head -n 1)

    if [ ! -f "$BACKUP_FILE" ]; then
        echo "❌ Backup for VM $VMID not found. Skipping."
        FAILED_IDS+=("$VMID")
        continue
    fi

    echo "📤 Transferring $BACKUP_FILE to $TARGET_HOST with progress..."
    rsync -ah --progress "$BACKUP_FILE" "$SSH_USER@$TARGET_HOST:$REMOTE_DUMP_PATH/"
    if [ $? -ne 0 ]; then
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
