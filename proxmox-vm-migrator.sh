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

VERSION="1.1.0"
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
if [ -f "$CONFIG_FILE" ]; then
    LAST_TARGET=$(cat "$CONFIG_FILE")
    echo "📁 Last target host: $LAST_TARGET"
else
    LAST_TARGET="(none)"
fi

read -p "🖥️ Enter target Proxmox host IP or hostname [${LAST_TARGET}]: " TARGET_HOST
TARGET_HOST="${TARGET_HOST:-$LAST_TARGET}"

if [ -z "$TARGET_HOST" ]; then
    echo "❌ No target host provided. Aborting."
    exit 1
fi
echo "$TARGET_HOST" > "$CONFIG_FILE"

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
    vzdump $VMID --compress zstd --storage local
    BACKUP_FILE=$(ls -t $DUMP_PATH/vzdump-qemu-${VMID}-*.zst | head -n 1)

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
