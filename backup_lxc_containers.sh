#!/bin/bash

# HA-Aware Proxmox Container Backup Script
# 
# IMPORTANT - Bash Return Code Convention:
# All functions in this script follow standard Unix/Bash return code semantics:
# - Return 0 = SUCCESS/TRUE (operation succeeded, condition is true)
# - Return 1 = FAILURE/FALSE (operation failed, condition is false)
# 
# This is the opposite of mathematical boolean logic but follows Unix tradition
# where programs exit with 0 for "everything went fine" and non-zero for errors.
#
# Examples:
# - is_container_healthy() returns 0 if healthy, 1 if unhealthy
# - backup_container() returns 0 if backup succeeded, 1 if failed
# - Usage: if is_container_healthy $id; then echo "healthy"; fi
#
# When in doubt: 0 = good/success/true, 1 = bad/failure/false

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

# Function to check if container runs locally on this HA node
# WHY: In HA clusters, containers may be running on different nodes. We only backup
# containers that are actually accessible from the current node to avoid conflicts.
# Returns: 0 if container is local and accessible, 1 if not local or not accessible
check_container_runs_locally() {
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


# Function to create backup lock file for coordination between nodes
# WHY: Prevents multiple nodes from backing up the same container simultaneously.
# In HA clusters, containers can migrate between nodes during backup windows.
# Returns: 0 if lock created successfully, 1 if lock already exists or creation failed
create_backup_lock_file() {
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
# WHY: Clean up coordination lock after backup completion or failure.
# Must always succeed to prevent permanent locks.
# Returns: Always returns 0 (never fails)
remove_backup_lock_file() {
	local container_id=$1
	local lock_file="/tmp/backup-${container_id}.lock"
	rm -f "$lock_file" >/dev/null 2>&1
}

# Function to record container's initial state before backup
# WHY: We must restore the container to exactly the same state after backup.
# If container was running, restore to running. If stopped, leave stopped.
# Returns: Always returns 0 (success), outputs "running" or "stopped" to stdout
record_container_initial_state() {
	local container_id=$1
	
	# Check current container status
	# WHY: This determines whether we need to restart container after backup
	if pct status $container_id 2>/dev/null | grep -q "running"; then
		echo "running"  # Output state to stdout for caller to capture
		echo "Container $container_id initial state: RUNNING" >&2
	else
		echo "stopped"  # Output state to stdout for caller to capture
		echo "Container $container_id initial state: STOPPED" >&2
	fi
	
	return 0  # Always succeeds - we can always determine state
}

# Function to execute the actual container backup using vzdump
# WHY: Core backup operation that creates the backup file. Uses timeout to prevent
# hanging backups that could block other containers or fill up disk space.
# Returns: 0 if backup completed successfully, 1 if backup failed or timed out
execute_container_backup() {
	local container_id=$1
	
	if [ "$DRY_RUN" = true ]; then
		echo "[DRY RUN] Would execute: timeout 10800 vzdump $container_id --dumpdir $LOCAL_BACKUP_DIR --mode snapshot --compress $COMPRESSION --mailto \"$EMAIL_RECIPIENT\""
		return 0  # Success in dry run mode
	fi
	
	echo "Executing backup for container $container_id..."
	
	# Execute vzdump with 3-hour timeout (10800 seconds)
	# WHY: Timeout prevents indefinitely hanging backups that could block the entire process
	# 3 hours should be sufficient even for very large containers
	timeout 10800 vzdump $container_id --dumpdir $LOCAL_BACKUP_DIR --mode snapshot --compress $COMPRESSION --mailto "$EMAIL_RECIPIENT"
	local backup_result=$?
	
	# Always unlock container after backup operation
	# WHY: vzdump may lock container during backup, unlock ensures container can be managed
	echo "Unlocking container $container_id after backup..."
	pct unlock $container_id 2>/dev/null || true
	
	# Analyze backup result
	if [ $backup_result -eq 124 ]; then
		echo "ERROR: Backup timed out after 3 hours for container $container_id"
		return 1  # Timeout failure
	elif [ $backup_result -ne 0 ]; then
		echo "ERROR: Backup failed for container $container_id (exit code: $backup_result)"
		return 1  # Backup process failure
	fi
	
	echo "Backup execution completed successfully for container $container_id"
	return 0  # Backup success
}

# Function to ensure container matches its initial state after backup
# WHY: Backup process may stop containers or leave them in inconsistent states.
# We must restore containers to exactly their pre-backup state.
# Returns: 0 if container state matches initial state, 1 if restoration failed
ensure_container_matches_initial_state() {
	local container_id=$1
	local initial_state=$2  # "running" or "stopped"
	
	if [ "$DRY_RUN" = true ]; then
		echo "[DRY RUN] Would ensure container $container_id matches initial state: $initial_state"
		return 0  # Success in dry run mode
	fi
	
	if [ "$initial_state" = "stopped" ]; then
		# Container was stopped before backup - ensure it stays stopped
		# WHY: Respect the original container state, don't start containers that were stopped
		echo "Container $container_id was stopped before backup - ensuring it remains stopped"
		pct stop $container_id 2>/dev/null || true
		return 0  # Always succeeds for stopped containers
	elif [ "$initial_state" = "running" ]; then
		# Container was running before backup - ensure it's running and healthy
		# WHY: Running containers must be restored to working state after backup
		echo "Container $container_id was running before backup - restoring to running state"
		
		# Start container if not already running
		if ! pct status $container_id | grep -q "running"; then
			echo "Starting container $container_id..."
			pct start $container_id 2>/dev/null || true
			sleep 15  # Allow time for container startup
		fi
		
		# Verify container is healthy and accessible
		if verify_container_basic_health $container_id; then
			echo "Container $container_id successfully restored to running state"
			return 0  # Success - container running and healthy
		else
			echo "ERROR: Container $container_id failed to restore to healthy running state"
			return 1  # Failure - container not healthy
		fi
	else
		echo "ERROR: Unknown initial state '$initial_state' for container $container_id"
		return 1  # Invalid state parameter
	fi
}

# Function to verify basic container health for running containers
# WHY: After backup operations, running containers must be able to execute commands
# and have basic processes running. This ensures the container is actually functional.
# Returns: 0 if container is healthy, 1 if container has health issues
verify_container_basic_health() {
	local container_id=$1
	local max_attempts=3
	local attempt=1
	
	while [ $attempt -le $max_attempts ]; do
		echo "Health verification attempt $attempt/$max_attempts for container $container_id"
		
		# Check 1: Container reports running status
		# WHY: Container must be in running state before we can verify health
		if ! pct status $container_id | grep -q "running"; then
			echo "Container $container_id is not running, attempting to start..."
			pct start $container_id 2>/dev/null || true
			sleep 10
			attempt=$((attempt + 1))
			continue
		fi
		
		# Check 2: Command execution test
		# WHY: Most critical test - if container can't execute commands, it's broken
		if ! timeout 10 pct exec $container_id -- echo "health_verification" >/dev/null 2>&1; then
			echo "Container $container_id command execution failed, restarting container..."
			pct stop $container_id 2>/dev/null || true
			sleep 5
			pct start $container_id 2>/dev/null || true
			sleep 15
			attempt=$((attempt + 1))
			continue
		fi
		
		# Check 3: Minimum process count
		# WHY: Containers should have at least a few processes. Too few indicates service failure
		local process_count=$(timeout 10 pct exec $container_id -- ps aux 2>/dev/null | wc -l)
		if [ -z "$process_count" ] || [ "$process_count" -lt 3 ]; then
			echo "Container $container_id has insufficient processes ($process_count), restarting..."
			pct stop $container_id 2>/dev/null || true
			sleep 5
			pct start $container_id 2>/dev/null || true
			sleep 15
			attempt=$((attempt + 1))
			continue
		fi
		
		echo "Container $container_id passed basic health verification"
		return 0  # All checks passed - container is healthy
	done
	
	echo "CRITICAL: Container $container_id failed health verification after $max_attempts attempts"
	return 1  # Health verification failed
}

# Function to send immediate failure notification via email
# WHY: Critical failures require immediate attention. Email notifications ensure
# administrators are alerted to backup failures or container health issues.
# Returns: Always returns 0 (notification sending never blocks backup process)
send_failure_notification() {
	local container_id=$1
	local failure_type=$2  # e.g., "BACKUP FAILED", "CONTAINER HEALTH FAILED"
	local failure_details=$3
	
	if [ "$DRY_RUN" = true ]; then
		echo "[DRY RUN] Would send $failure_type notification for container $container_id"
		echo "[DRY RUN] Email content: $failure_details"
		return 0  # Success in dry run mode
	fi
	
	# Send email notification with failure details
	# WHY: Immediate notification allows quick response to critical issues
	echo "$failure_details" | mail -s "$failure_type - Container $container_id on $(hostname)" "$EMAIL_RECIPIENT"
	echo "Sent $failure_type notification email for container $container_id"
	
	return 0  # Always succeeds - email failure should not block backup process
}

# Main function to backup a single container with step-specific error handling
# WHY: Each step is independent - if backup succeeds but S3 fails, we keep the backup
# and only fail the S3 step. No step should prevent other steps from attempting.
# Returns: 0 if critical steps succeeded, 1 if critical steps failed
backup_single_container() {
	local container_id=$1
	local backup_created=false
	local state_restored=false
	local s3_uploaded=false
	local overall_success=true
	
	echo "=== Starting backup cycle for container $container_id ==="
	
	# Step 1: Check if container runs locally on this HA node
	# WHY: Only backup containers that are accessible from current node
	if ! check_container_runs_locally $container_id; then
		echo "Container $container_id not local to this node - skipping entirely"
		return 1  # Not local - skip this container completely
	fi
	
	# Note: Removed "backup already exists today" check
	# WHY: Multiple backups per day should be allowed for various reasons:
	# - Before/after major changes, manual backup requests, retry after failures
	# - Time-based backup names ensure uniqueness without blocking multiple backups
	
	# Step 3: Record container's initial state
	# WHY: Must restore container to exact same state after backup
	local initial_state=$(record_container_initial_state $container_id)
	echo "Recorded initial state: $initial_state"
	
	# Step 4: Create backup lock file for node coordination
	# WHY: Prevent multiple nodes from backing up same container
	if ! create_backup_lock_file $container_id; then
		echo "Cannot create backup lock for container $container_id - skipping entirely"
		return 1  # Lock conflict - skip this container completely
	fi
	
	# Step 5: Execute the actual backup (CRITICAL - cannot continue without this)
	# WHY: This is the core operation - if this fails, nothing else matters
	# Step 5a: Clean up any stale vzdump snapshots before backup
	# WHY: Previous failed backups may leave stale ZFS snapshots that block new backups
	echo "🧼 Cleaning up stale snapshots before backup..."
	cleanup_stale_vzdump_snapshots $container_id
	
	echo "📦 Executing backup for container $container_id..."
	if execute_container_backup $container_id; then
		backup_created=true
		echo "✅ Backup file created successfully"
	else
		echo "❌ CRITICAL: Backup execution failed for container $container_id"
		send_failure_notification $container_id "BACKUP EXECUTION FAILED" "Backup process failed for container $container_id on node $(hostname) at $(date). Check logs for details."
		remove_backup_lock_file $container_id
		return 1  # Cannot continue without backup file
	fi
	
	# Step 6: Restore container to initial state (CRITICAL for running containers)
	# WHY: Running containers must be restored to working state, but this shouldn't stop S3 upload
	echo "🔄 Restoring container to initial state: $initial_state"
	if ensure_container_matches_initial_state $container_id $initial_state; then
		state_restored=true
		echo "✅ Container restored to initial state successfully"
	else
		echo "❌ WARNING: Container state restoration failed but continuing with S3 upload"
		send_failure_notification $container_id "CONTAINER STATE RESTORATION FAILED" "Container $container_id failed to restore to initial state '$initial_state' after backup on node $(hostname) at $(date). Backup file exists and will be uploaded to S3."
		overall_success=false  # Mark as partial failure but continue
	fi
	
	# Step 7: Upload backup files to S3 storage (IMPORTANT but independent of container state)
	# WHY: Even if container health failed, we should still save the backup file to S3
	echo "☁️ Uploading backup files to S3..."
	if verify_and_retry_s3_upload $container_id; then
		s3_uploaded=true
		echo "✅ Backup files uploaded to S3 successfully"
	else
		echo "❌ WARNING: S3 upload failed but backup file exists locally"
		send_failure_notification $container_id "S3 UPLOAD FAILED" "Backup for container $container_id completed successfully but failed to upload to S3 after multiple retries on node $(hostname) at $(date). Backup files are available locally: $LOCAL_BACKUP_DIR"
		overall_success=false  # Mark as partial failure but continue
	fi
	
	# Step 8: Clean up old backup files (NON-CRITICAL)
	# WHY: Cleanup failure should never affect overall backup success
	echo "🧹 Cleaning up old backup files..."
	if cleanup_old_backup_files $container_id; then
		echo "✅ Old backup files cleaned up successfully"
	else
		echo "⚠️ WARNING: Old backup cleanup had issues (non-critical)"
	fi
	
	# Step 9: Always remove backup lock file
	# WHY: Lock cleanup must always happen regardless of other step results
	remove_backup_lock_file $container_id
	echo "🔓 Backup lock removed"
	
	# Summary of results
	echo "=== Backup Summary for container $container_id ==="
	echo "📦 Backup created: $([ "$backup_created" = true ] && echo "✅ YES" || echo "❌ NO")"
	echo "🔄 State restored: $([ "$state_restored" = true ] && echo "✅ YES" || echo "❌ NO")"
	echo "☁️ S3 uploaded: $([ "$s3_uploaded" = true ] && echo "✅ YES" || echo "❌ NO")"
	
	if [ "$overall_success" = true ]; then
		echo "🎉 SUCCESS: All critical steps completed for container $container_id"
		return 0
	else
		echo "⚠️ PARTIAL SUCCESS: Backup created but some steps failed for container $container_id"
		return 1
	fi
}

# Function to clean up stale vzdump snapshots that block new backups
# WHY: Failed or interrupted backups leave stale ZFS snapshots that prevent new backups
# Returns: Always returns 0 (cleanup issues are non-critical)
cleanup_stale_vzdump_snapshots() {
	local container_id=$1
	
	if [ "$DRY_RUN" = true ]; then
		echo "[DRY RUN] Would check for and remove stale vzdump snapshots for container $container_id"
		return 0
	fi
	
	# Find ZFS datasets for this container that might have stale vzdump snapshots
	# WHY: Container storage can be on different ZFS datasets, we need to check all possibilities
	local datasets=""
	
	# Try common ZFS dataset patterns for Proxmox containers
	local possible_datasets=(
		"data/containers/subvol-${container_id}-disk-0"
		"rpool/data/containers/subvol-${container_id}-disk-0"  
		"data/subvol-${container_id}-disk-0"
		"local-zfs/subvol-${container_id}-disk-0"
	)
	
	for dataset in "${possible_datasets[@]}"; do
		if zfs list "$dataset" >/dev/null 2>&1; then
			datasets="$datasets $dataset"
		fi
	done
	
	# Clean up stale vzdump snapshots from found datasets
	if [ -n "$datasets" ]; then
		echo "Checking for stale vzdump snapshots in datasets:$datasets"
		for dataset in $datasets; do
			local snapshot="${dataset}@vzdump"
			if zfs list "$snapshot" >/dev/null 2>&1; then
				echo "Removing stale snapshot: $snapshot"
				if zfs destroy "$snapshot" 2>/dev/null; then
					echo "✅ Removed stale snapshot: $snapshot"
				else
					echo "⚠️ WARNING: Could not remove stale snapshot: $snapshot"
				fi
			fi
		done
	else
		echo "No ZFS datasets found for container $container_id - snapshots not applicable"
	fi
	
	return 0  # Always succeed - snapshot cleanup issues shouldn't block backup
}

# Function to clean up old backup files beyond retention period
# WHY: Prevent S3 storage from growing indefinitely. Remove backups older than
# configured retention period to manage storage costs and comply with data policies.
# Returns: 0 if cleanup completed, 1 if cleanup failed
cleanup_old_backup_files() {
	local container_id=$1
	
	if [ "$DRY_RUN" = true ]; then
		echo "[DRY RUN] Would clean old backups for container $container_id older than $DAYS_TO_KEEP days"
		# Show what would be deleted in dry run
		find $TARGET_BACKUP_DIR -type f \( -name "vzdump-lxc-$container_id-*.tar" -o -name "vzdump-lxc-$container_id-*.tar.gz" -o -name "vzdump-lxc-$container_id-*.lzo" -o -name "vzdump-lxc-$container_id-*.zst" -o -name "vzdump-lxc-$container_id-*.vma" -o -name "vzdump-lxc-$container_id-*.log" \) -mtime +$DAYS_TO_KEEP 2>/dev/null | while read file; do
			echo "[DRY RUN] Would remove old backup: $file"
		done
		return 0  # Success in dry run mode
	fi
	
	echo "Cleaning old backups for container $container_id (keeping $DAYS_TO_KEEP days)..."
	
	# Find and remove backup files older than retention period
	# WHY: Multiple file extensions supported as vzdump can create different formats
	local cleanup_result=0
	find $TARGET_BACKUP_DIR -type f \( -name "vzdump-lxc-$container_id-*.tar" -o -name "vzdump-lxc-$container_id-*.tar.gz" -o -name "vzdump-lxc-$container_id-*.lzo" -o -name "vzdump-lxc-$container_id-*.zst" -o -name "vzdump-lxc-$container_id-*.vma" -o -name "vzdump-lxc-$container_id-*.log" \) -mtime +$DAYS_TO_KEEP -delete 2>/dev/null || cleanup_result=1
	
	if [ $cleanup_result -eq 0 ]; then
		echo "Successfully cleaned old backups for container $container_id"
		return 0  # Cleanup successful
	else
		echo "WARNING: Some old backup files for container $container_id could not be removed"
		return 1  # Cleanup had issues
	fi
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

# Main backup loop - each container processed once
# WHY: Each step within backup_single_container handles its own retries.
# No need to retry entire backup process - if backup succeeds but S3 fails, 
# we keep the backup file and only retry S3 upload internally.
echo "Starting backup process for containers: ${CONTAINER_LIST[*]}"

for container_id in "${CONTAINER_LIST[@]}"; do
	echo -e "\n=== Processing container $container_id ==="
	
	# Call the single backup function that handles everything with internal step-specific retries
	# WHY: Each critical step (S3 upload, health checks) has its own retry logic built-in
	if backup_single_container $container_id; then
		echo "✅ Container $container_id backup cycle completed successfully"
	else
		echo "❌ Container $container_id backup cycle failed"
		BACKUP_SUCCESS=false
	fi
done

# Final verification - simple check that all containers are in expected state
# WHY: Quick final verification ensures containers are still accessible after all backup operations
echo "Performing final verification on all processed containers..."

for container_id in "${CONTAINER_LIST[@]}"; do
	if check_container_runs_locally $container_id; then
		echo "Final check for container $container_id..."
		
		if [ "$DRY_RUN" = true ]; then
			echo "[DRY RUN] Would perform final health check on container $container_id"
		else
			# Simple final check - just verify container can execute commands
			if pct status $container_id | grep -q "running"; then
				if timeout 10 pct exec $container_id -- echo "final_check" >/dev/null 2>&1; then
					echo "Container $container_id final check: HEALTHY"
				else
					echo "WARNING: Container $container_id not responding to commands"
				fi
			else
				echo "Container $container_id final check: STOPPED (as expected)"
			fi
		fi
	fi
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
