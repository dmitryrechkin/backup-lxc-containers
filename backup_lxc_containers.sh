#!/bin/bash

# Parse command line arguments
for arg in "$@"; do
	case $arg in
		--dry-run)
			DRY_RUN=true
			shift
			;;
		-h|--help)
			echo "Usage: $0 [--dry-run] [--help]"
			echo "  --dry-run    Test mode - shows what would be done without executing"
			echo "  --help       Show this help message"
			exit 0
			;;
		*)
			echo "Unknown argument: $arg"
			echo "Use --help for usage information"
			exit 1
			;;
	esac
done

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
DRY_RUN=${DRY_RUN:-false}

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

# Function to check if container is running locally (HA-aware)
is_container_local() {
	local container_id=$1
	
	# Check if container exists locally
	if ! pct config $container_id >/dev/null 2>&1; then
		echo "Container $container_id does not exist on this node"
		return 1
	fi
	
	# Get container status
	local status=$(pct status $container_id 2>/dev/null | awk '{print $2}')
	
	if [[ "$status" == "running" ]]; then
		# Verify we can actually access the container (not just think it's running)
		if timeout 10 pct exec $container_id -- echo "test" >/dev/null 2>&1; then
			echo "Container $container_id is running locally on $(hostname)"
			return 0
		else
			echo "Container $container_id appears running but not accessible (likely on other node)"
			return 1
		fi
	elif [[ "$status" == "stopped" ]]; then
		echo "Container $container_id is stopped locally"
		return 0
	else
		echo "Container $container_id status: $status (skipping - not local)"
		return 1
	fi
}

# Function to check if backup already exists in S3 for today
backup_exists_today() {
	local container_id=$1
	local today=$(date +%Y-%m-%d)
	
	# Check if backup file exists in S3 for today
	if ls "$TARGET_BACKUP_DIR"/vzdump-lxc-$container_id-$today-*.* >/dev/null 2>&1; then
		echo "Backup for container $container_id already exists for $today"
		return 0
	else
		echo "No existing backup found for container $container_id today"
		return 1
	fi
}

# Function to create backup lock file
create_backup_lock() {
	local container_id=$1
	local lock_file="/tmp/backup-${container_id}.lock"
	local node_name=$(hostname)
	
	if [ -f "$lock_file" ]; then
		local lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_file") ))
		if [ $lock_age -gt 14400 ]; then  # 4 hours old
			echo "Removing stale lock file for container $container_id"
			rm -f "$lock_file"
		else
			echo "Backup already in progress for container $container_id"
			return 1
		fi
	fi
	
	echo "${node_name}:$$:$(date)" > "$lock_file"
	return 0
}

# Function to remove backup lock file
remove_backup_lock() {
	local container_id=$1
	local lock_file="/tmp/backup-${container_id}.lock"
	rm -f "$lock_file" >/dev/null 2>&1
}

# Function to verify S3 upload with retry
verify_and_retry_s3_upload() {
	local container_id=$1
	local backup_files=$(find $LOCAL_BACKUP_DIR -name "vzdump-lxc-$container_id-*" -newermt "$(date +%Y-%m-%d)" -type f)
	local max_retries=3
	local retry_count=0
	
	if [ -z "$backup_files" ]; then
		echo "No backup files found for container $container_id"
		return 1
	fi
	
	while [ $retry_count -lt $max_retries ]; do
		echo "Attempting to move backup files to S3 (attempt $((retry_count + 1))/$max_retries)..."
		
		# Try to move files
		if [ "$DRY_RUN" = true ]; then
			echo "[DRY RUN] Would move files: $backup_files to $TARGET_BACKUP_DIR/"
			echo "[DRY RUN] Would verify files in S3"
			return 0
		fi
		
		if mv $backup_files $TARGET_BACKUP_DIR/; then
			# Verify files actually exist in S3
			local moved_successfully=true
			for file in $backup_files; do
				local filename=$(basename "$file")
				if [ ! -f "$TARGET_BACKUP_DIR/$filename" ]; then
					echo "Failed to verify $filename in S3"
					moved_successfully=false
					break
				fi
			done
			
			if [ "$moved_successfully" = true ]; then
				echo "Successfully moved and verified backup files for container $container_id in S3"
				return 0
			else
				echo "S3 verification failed, files may not have been moved properly"
			fi
		else
			echo "Failed to move backup files to S3"
		fi
		
		retry_count=$((retry_count + 1))
		if [ $retry_count -lt $max_retries ]; then
			local sleep_time=$((retry_count * 60))  # Exponential backoff
			echo "Retrying in $sleep_time seconds..."
			sleep $sleep_time
		fi
	done
	
	echo "Failed to upload backup for container $container_id after $max_retries attempts"
	return 1
}

# Function to perform backup with timeout
backup_container() {
	local container_id=$1
	echo "Starting backup for container $container_id..."
	
	# Check container status before backup
	local was_running=$(pct status $container_id | grep -c "running")
	
	if [ "$DRY_RUN" = true ]; then
		echo "[DRY RUN] Would execute: timeout 10800 vzdump $container_id --dumpdir $LOCAL_BACKUP_DIR --mode snapshot --compress $COMPRESSION --mailto \"$EMAIL_RECIPIENT\""
		echo "[DRY RUN] Container was_running: $was_running"
		echo "[DRY RUN] Would unlock container and ensure it's running if needed"
		return 0
	fi
	
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

	if [ "$DRY_RUN" = true ]; then
		echo "[DRY RUN] Would clean old backups older than $DAYS_TO_KEEP days"
		find $TARGET_BACKUP_DIR -type f \( -name "vzdump-lxc-$container_id-*.tar" -o -name "vzdump-lxc-$container_id-*.tar.gz" -o -name "vzdump-lxc-$container_id-*.lzo" -o -name "vzdump-lxc-$container_id-*.zst" -o -name "vzdump-lxc-$container_id-*.vma" -o -name "vzdump-lxc-$container_id-*.log" \) -mtime +$DAYS_TO_KEEP | while read file; do
			echo "[DRY RUN] Would remove: $file"
		done
		return 0
	fi

	find $TARGET_BACKUP_DIR -type f \( -name "vzdump-lxc-$container_id-*.tar" -o -name "vzdump-lxc-$container_id-*.tar.gz" -o -name "vzdump-lxc-$container_id-*.lzo" -o -name "vzdump-lxc-$container_id-*.zst" -o -name "vzdump-lxc-$container_id-*.vma" -o -name "vzdump-lxc-$container_id-*.log" \) -mtime +$DAYS_TO_KEEP -exec rm -f {} \;
}

# Function to restart container
restart_container() {
	local container_id=$1
	echo "Restart $container_id container to fix possible issues..."
	
	if [ "$DRY_RUN" = true ]; then
		echo "[DRY RUN] Would execute: /usr/sbin/pct stop $container_id"
		echo "[DRY RUN] Would execute: /usr/sbin/pct start $container_id"
		return 0
	fi
	
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

# Send startup notification
if [ "$DRY_RUN" = true ]; then
	echo "[DRY RUN] Backup process analysis started at $(date) on node $(hostname)"
	echo "[DRY RUN] Would send email: Backup process started at $(date) on node $(hostname)"
else
	echo "Backup process started at $(date) on node $(hostname)" | mail -s "Proxmox Backup Started - Node $(hostname)" "$EMAIL_RECIPIENT"
fi

# Backup each container and handle relevant files
for container_id in "${CONTAINER_LIST[@]}"; do
	echo "Processing container $container_id..."
	
	# Check if container is local to this node
	if ! is_container_local $container_id; then
		echo "Container $container_id is not on this node, skipping..."
		continue
	fi
	
	# Check if backup already exists for today
	if backup_exists_today $container_id; then
		echo "Backup already exists for container $container_id today, skipping..."
		continue
	fi
	
	# Create backup lock to prevent conflicts
	if ! create_backup_lock $container_id; then
		echo "Cannot create backup lock for container $container_id, skipping..."
		continue
	fi
	
	echo "Starting backup process for container $container_id..."
	
	# Perform the backup
	if backup_container $container_id; then
		echo "Backup completed for container $container_id"
		restart_container $container_id
		
		# Use the new S3 verification function instead of simple move
		if verify_and_retry_s3_upload $container_id; then
			clean_old_backups $container_id
			echo "Backup completed successfully for container $container_id."
		else
			echo "Failed to upload backup files for container $container_id to S3."
			BACKUP_SUCCESS=false
		fi
	else
		echo "Backup failed for container $container_id."
		BACKUP_SUCCESS=false
	fi
	
	# Always remove the lock file
	remove_backup_lock $container_id
done

if [ "$DRY_RUN" = true ]; then
	echo "[DRY RUN] Analysis completed. No actual backups were performed."
	echo "[DRY RUN] Would send completion email based on results."
else
	if $BACKUP_SUCCESS; then
		echo "All local backups completed successfully on $(hostname)."
		echo "Container backup process completed successfully at $(date) on node $(hostname). Backups saved to S3 storage." | mail -s "Proxmox Backup SUCCESS - Node $(hostname)" "$EMAIL_RECIPIENT"
	else
		echo "Some backups failed on $(hostname)."
		echo "Backup process completed with ERRORS at $(date) on node $(hostname). Check logs for details." | mail -s "Proxmox Backup FAILED - Node $(hostname)" "$EMAIL_RECIPIENT"
	fi
fi
