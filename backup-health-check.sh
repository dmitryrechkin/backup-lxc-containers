#!/bin/bash
#
# Independent watchdog for the LXC/VM backup pipeline.
#
# WHY: The main backup script alerts on its own failures, but if it dies early or
# its mail path breaks, a slow-rot failure (off-site uploads silently failing while
# local staging fills) can go unnoticed for days. This external check runs on its own
# timer and emails ONLY when something is wrong, so the pipeline can't fail silently.
#
# Checks:
#   1. Free space in the local staging dir is above a threshold.
#   2. Every configured container has a recent backup on the rclone remote.

set -u

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"

# Reuse the backup pipeline's own configuration.
if [ -f "$SCRIPT_DIR/.env" ]; then
	# shellcheck disable=SC2046
	export $(grep -v '^#' "$SCRIPT_DIR/.env" | xargs)
fi

LOCAL_BACKUP_DIR=${LOCAL_BACKUP_DIR:-/var/lib/vz/dump}
RCLONE_REMOTE=${RCLONE_REMOTE:-}
EMAIL_RECIPIENT=${EMAIL_RECIPIENT:-root}
CONTAINER_LIST=(${CONTAINERS//,/ })
# Alert if staging free space drops below this (MB). Default: half the min-free guard.
HEALTH_MIN_FREE_MB=${HEALTH_MIN_FREE_MB:-${MIN_FREE_MB:-10000}}
# Alert if a container's newest remote backup is older than this many days.
HEALTH_MAX_BACKUP_AGE_DAYS=${HEALTH_MAX_BACKUP_AGE_DAYS:-2}

problems=()

# --- Check 1: local staging free space ---------------------------------------
free_mb=$(df -Pm "$LOCAL_BACKUP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
if [ -z "$free_mb" ]; then
	problems+=("Could not read free space for $LOCAL_BACKUP_DIR")
elif [ "$free_mb" -lt "$HEALTH_MIN_FREE_MB" ]; then
	problems+=("Staging dir $LOCAL_BACKUP_DIR low on space: ${free_mb}MB free (threshold ${HEALTH_MIN_FREE_MB}MB)")
fi

# --- Check 2: freshness of each container's newest remote backup -------------
if [ -n "$RCLONE_REMOTE" ]; then
	cutoff_epoch=$(date -d "$HEALTH_MAX_BACKUP_AGE_DAYS days ago" +%s)
	remote_listing=$(rclone lsf "$RCLONE_REMOTE" --files-only 2>/dev/null)
	if [ -z "$remote_listing" ]; then
		problems+=("Could not list remote $RCLONE_REMOTE (rclone/S3 connectivity?)")
	else
		for container_id in "${CONTAINER_LIST[@]}"; do
			# Match data files for this id: vzdump-<type>-<id>-YYYY_MM_DD-*.{tar.zst,vma.zst}
			newest_date=$(echo "$remote_listing" \
				| grep -E "vzdump-[a-z]+-${container_id}-[0-9]{4}_[0-9]{2}_[0-9]{2}-.*\.(tar\.zst|vma\.zst)$" \
				| grep -oE "[0-9]{4}_[0-9]{2}_[0-9]{2}" | sort | tail -1)
			if [ -z "$newest_date" ]; then
				problems+=("Container $container_id: NO data backup found on $RCLONE_REMOTE")
				continue
			fi
			newest_epoch=$(date -d "${newest_date//_/-}" +%s 2>/dev/null)
			if [ -n "$newest_epoch" ] && [ "$newest_epoch" -lt "$cutoff_epoch" ]; then
				problems+=("Container $container_id: newest off-site backup is $newest_date (older than ${HEALTH_MAX_BACKUP_AGE_DAYS} days)")
			fi
		done
	fi
fi

# --- Report ------------------------------------------------------------------
if [ ${#problems[@]} -eq 0 ]; then
	echo "Backup health OK on $(hostname) at $(date): ${free_mb}MB free, all containers have recent off-site backups."
	exit 0
fi

report="Backup health check found ${#problems[@]} problem(s) on $(hostname) at $(date):"
for problem in "${problems[@]}"; do
	report+=$'\n  - '"$problem"
done
echo "$report"
echo "$report" | mail -s "Proxmox Backup HEALTH WARNING - Node $(hostname)" "$EMAIL_RECIPIENT"
exit 1
