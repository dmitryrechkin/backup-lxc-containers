#!/bin/bash

# Determine the directory where the script is located
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Function to load .env file from the script's directory
load_env() {
	if [ -f "$SCRIPT_DIR/.env" ]; then
		export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
	fi
}

# Load environment variables from .env file
load_env

# Variables from .env file
CONTAINER_LIST=(${CONTAINERS//,/ })
DAYS_TO_KEEP=${DAYS_TO_KEEP:-7}
LOCAL_BACKUP_DIR=${LOCAL_BACKUP_DIR:-/var/lib/vz/dump}
TARGET_BACKUP_DIR=${TARGET_BACKUP_DIR:-$LOCAL_BACKUP_DIR}
BACKUP_SUCCESS=true
EMAIL_RECIPIENT=${EMAIL_RECIPIENT:-root}

# Check if target backup directory is mounted
if [ "$TARGET_BACKUP_DIR" != "$LOCAL_BACKUP_DIR" ]; then
	if ! mountpoint -q $TARGET_BACKUP_DIR; then
		echo "Target backup directory $TARGET_BACKUP_DIR is not mounted. Exiting..."
		exit 1
	fi
fi

# Check if any containers are defined
if [ ${#CONTAINER_LIST[@]} -eq 0 ]; then
	echo "No containers defined. Exiting..."
	exit 1
fi

# Check if vzdump is installed
if ! command -v vzdump &> /dev/null; then
	echo "vzdump is not installed. Exiting..."
	exit 1
fi

# Function to perform backup
backup_container() {
	local container_id=$1
	vzdump $container_id --dumpdir $LOCAL_BACKUP_DIR --mode snapshot --compress gzip --mailto "$EMAIL_RECIPIENT"
	return $?
}

# Function to clean old backups for a specific container
clean_old_backups() {
	local container_id=$1
	find $TARGET_BACKUP_DIR -type f -name "vzdump-lxc-$container_id-*.tar" -o -name "vzdump-lxc-$container_id-*.tar.gz" -o -name "vzdump-lxc-$container_id-*.lzo" -o -name "vzdump-lxc-$container_id-*.vma" -o -name "vzdump-lxc-$container_id-*.log" -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
}

# Backup each container and handle relevant files
for container_id in "${CONTAINER_LIST[@]}"; do
	backup_container $container_id
	if [ $? -eq 0 ]; then
		echo "Backup successful for container $container_id. Moving to target backup folder and cleaning old backups..."
		mv $LOCAL_BACKUP_DIR/vzdump-lxc-$container_id-* $TARGET_BACKUP_DIR/
		clean_old_backups $container_id
	else
		echo "Backup failed for container $container_id."
		BACKUP_SUCCESS=false
	fi
done

if $BACKUP_SUCCESS; then
	echo "All backups completed successfully."
else
	echo "Some backups failed."
fi
