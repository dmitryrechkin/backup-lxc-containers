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
COMPRESSION=${COMPRESSION:-gzip}
CHECK_MOUNTPOINT=${CHECK_MOUNTPOINT:-false}

# Function to check if any part of the path is a mount point
check_mount_point() {
	local path=$1
	echo "Checking if $path is a mount point..."

	while [ "$path" != "/" ]; do
		echo "Checking $path..."
		if mountpoint -q "$path"; then
			echo "$path is a mount point."
			return 0
		fi
		path=$(dirname "$path")
	done

	echo "No mount point found for $path."
	return 1
}

# Function to perform backup
backup_container() {
	local container_id=$1
	vzdump $container_id --dumpdir $LOCAL_BACKUP_DIR --mode snapshot --compress $COMPRESSION --mailto "$EMAIL_RECIPIENT"
	return $?
}

# Function to clean old backups for a specific container
clean_old_backups() {
	echo "Cleaning old backups for container $container_id..."
	local container_id=$1

	# Output for debugging
	echo "find $TARGET_BACKUP_DIR -type f \( -name "vzdump-lxc-$container_id-*.tar" -o -name "vzdump-lxc-$container_id-*.tar.gz" -o -name "vzdump-lxc-$container_id-*.lzo" -o -name "vzdump-lxc-$container_id-*.zst" -o -name "vzdump-lxc-$container_id-*.vma" -o -name "vzdump-lxc-$container_id-*.log" \) -mtime +$DAYS_TO_KEEP -exec rm -f {} \;"

	find $TARGET_BACKUP_DIR -type f \( -name "vzdump-lxc-$container_id-*.tar" -o -name "vzdump-lxc-$container_id-*.tar.gz" -o -name "vzdump-lxc-$container_id-*.lzo" -o -name "vzdump-lxc-$container_id-*.zst" -o -name "vzdump-lxc-$container_id-*.vma" -o -name "vzdump-lxc-$container_id-*.log" \) -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
}

# Function to restart container
restart_container() {
	local container_id=$1
	echo "Restart $container_id container to fix possible issues..."
	/usr/sbin/pct stop $container_id
	/usr/sbin/pct start $container_id
}

# Function to move backups to target backup directory
move_to_target_backup_dir() {
	local container_id=$1
	echo "Moving $container_id backups to target backup directory..."
	mv $LOCAL_BACKUP_DIR/vzdump-lxc-$container_id-* $TARGET_BACKUP_DIR/
}

# Check if target backup directory is mounted, if required
if [ "$CHECK_MOUNTPOINT" = true ] && [ "$TARGET_BACKUP_DIR" != "$LOCAL_BACKUP_DIR" ]; then
	if ! check_mount_point "$TARGET_BACKUP_DIR"; then
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

# Backup each container and handle relevant files
for container_id in "${CONTAINER_LIST[@]}"; do
	backup_container $container_id
	if [ $? -eq 0 ]; then
		restart_container $container_id
		move_to_target_backup_dir $container_id
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
