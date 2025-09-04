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

# Function to perform backup with timeout
backup_container() {
	local container_id=$1
	echo "Starting backup for container $container_id..."
	
	# Check container status before backup
	local was_running=$(pct status $container_id | grep -c "running")
	
	timeout 10800 vzdump $container_id --dumpdir $LOCAL_BACKUP_DIR --mode snapshot --compress $COMPRESSION --mailto "$EMAIL_RECIPIENT"
	local result=$?
	
	# Always unlock container first
	echo "Unlocking container $container_id..."
	pct unlock $container_id 2>/dev/null || true
	
	# Ensure container is running after backup if it was running before
	if [ $was_running -gt 0 ]; then
		echo "Ensuring container $container_id is running..."
		pct start $container_id 2>/dev/null || true
		
		# Verify it actually started
		sleep 5
		local is_running=$(pct status $container_id | grep -c "running")
		if [ $is_running -eq 0 ]; then
			echo "WARNING: Failed to start container $container_id after backup"
		else
			echo "Container $container_id is running successfully"
		fi
	fi
	
	if [ $result -eq 124 ]; then
		echo "Backup timed out after 3 hours for container $container_id"
		return 1
	fi
	
	return $result
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
	
	# Find backup files for this container from today
	local backup_files=$(find $LOCAL_BACKUP_DIR -name "vzdump-lxc-$container_id-*" -newermt "$(date +%Y-%m-%d)" -type f)
	
	if [ -n "$backup_files" ]; then
		mv $backup_files $TARGET_BACKUP_DIR/
		echo "Moved backup files for container $container_id"
	else
		echo "No backup files found for container $container_id to move"
		return 1
	fi
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
		if move_to_target_backup_dir $container_id; then
			clean_old_backups $container_id
			echo "Backup completed successfully for container $container_id."
		else
			echo "Failed to move backup files for container $container_id."
			BACKUP_SUCCESS=false
		fi
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
