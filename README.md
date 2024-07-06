# Proxmox LXC Container Backup Script

This script automates the daily backup of Proxmox LXC containers, ensuring that backups are retained for a specified number of days and are copied to a mounted target directory only if they succeed. The script is designed to be configurable and reusable across multiple servers.

## Objective/Rationale

Automating the backup process helps ensure that your Proxmox containers are regularly backed up without manual intervention. This script:
- Performs daily backups of specified containers.
- Retains backups for a configurable number of days.
- Copies successful backups to a mounted target directory (NFS, FTP, S3, etc.).
- Sends email notifications upon successful backups.
- Ensures the target backup directory is mounted before proceeding.

## Getting Started

### Prerequisites

- Proxmox Virtual Environment
- `vzdump` command available
- Mounted target directory (NFS, FTP, S3, etc.)

### Clone the Repository

Clone this repository to your local machine:

```sh
git clone https://github.com/dmitryrechkin/backup-lxc-containers.git
cd backup-lxc-containers
```

### Setup

1. **Create a `.env` or Copy `.env.example` File:**

   Create a `.env` file in the cloned directory and configure the following variables:

   ```sh
   LOCAL_BACKUP_DIR="/var/lib/vz/dump"
   TARGET_BACKUP_DIR="/mnt/backup-target"
   CONTAINERS="102,103"
   DAYS_TO_KEEP=7
   EMAIL_RECIPIENT="your-email@example.com"
   ```

   - `LOCAL_BACKUP_DIR`: Directory where local backups will be stored.
   - `TARGET_BACKUP_DIR`: Target directory where successful backups will be copied.
   - `CONTAINERS`: Comma-separated list of container IDs to back up.
   - `DAYS_TO_KEEP`: Number of days to retain backups (default is 7).
   - `EMAIL_RECIPIENT`: Email address to notify upon successful backups.
   - `COMPRESSION`: Compression used for the backup.
   - `CHECK_MOUNTPOINT`: Check if any part of the path is a mount point. It is useful when backing up to an external target like an S3 bucket.

2. **Make the Script Executable:**

   ```sh
   chmod +x backup_lxc_container.sh
   ```

### Usage

Run the script manually to test it:

```sh
./backup_lxc_container.sh
```

### Schedule the Script

To schedule the script to run daily using cron, follow these steps:

1. Edit the crontab for root (since Proxmox usually requires root access for backup operations):

   ```sh
   crontab -e
   ```

2. Add the following line to run the script every day at 2 AM (adjust the time as needed):

   ```sh
   0 2 * * * /path/to/your/backup_lxc_container.sh
   ```

### Examples

**Example 1: Basic Setup**

Configure the `.env` file for basic usage:

```env
LOCAL_BACKUP_DIR="/var/lib/vz/dump"
TARGET_BACKUP_DIR="/mnt/backup-target"
CONTAINERS="102,103"
DAYS_TO_KEEP=7
EMAIL_RECIPIENT="your-email@example.com"
COMPRESSION="zst"
CHECK_MOUNTPOINT=true
```

Run the script manually:

```sh
./backup_lxc_container.sh
```

**Example 2: Custom Configuration**

Configure the `.env` file with a different set of containers and retention period:

```env
LOCAL_BACKUP_DIR="/var/lib/vz/dump"
TARGET_BACKUP_DIR="/mnt/backup-target"
CONTAINERS="104,105,106"
DAYS_TO_KEEP=5
EMAIL_RECIPIENT="admin@example.com"
COMPRESSION="gzip"
CHECK_MOUNTPOINT=true
```

Schedule the script to run daily at 3 AM:

```sh
0 3 * * * /path/to/your/backup_lxc_container.sh
```

Good Luck!
