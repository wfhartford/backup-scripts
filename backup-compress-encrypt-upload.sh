#!/usr/bin/env bash

# Backup compress encrypt upload
#
# As the name suggests, this script does a few things:
#   1. Create a new backup snapshot using timeshift; timeshift is executed by
#      this script, but needs to be configured externally,
#   2. Compresses the most recent timeshift snapshot as a tarball,
#   3. Encrypts the compressed backup using gpg,
#   4. Uploads the encrypted backup to OneDrive.
#
# The script must be run as super user, and does not take any command line
# arguments:
#   sudo ./backup-compress-encrypt-upload.sh
#
# This script integrates with BitWarden to retrieve and store necessary
# secrets:
#   * Timeshift's destination device is encrypted and the unlock passphrase is
#     retrieved from BitWarden when needed.
#   * The backup tarball is encrypted using gpg's symmetric encryption mode,
#     each backup uses a different passphrase which is generated from
#     /dev/urandom and stored to BitWarden.
#
# The specifics of the script are stored in a JSON formatted configuration
# file, which is located in /root/.config/backup/config.json. The expected
# content of this config file can be inferred from the variable initialisation
# code below.
#
# External pre-requisites:
# * bash - to execute this file
# * tar - is there a *nix distro without it?
# * gzip - is there a *nix distro without it?
# * du - common utility for measuring size of files and directory trees.
# * udisksctl - simplifies working with encrypted devices, available on most
#   modern distributions.
# * jq - common utility for manipulating JSON files.
# * gpg - common open-source encryption tool.
# * rclone - tool for interacting with cloud storage providers.
# * bitwarden cli - Command line tool for interacting with a BitWarden vault,
#   not very common, so is the only one with a configurable executable
#   location.
#
set -eu
IFS=$'\n\t'

if ! [ "$(id -u)" = 0 ]; then
   echo "The script need to be run as root." > /dev/stderr
   exit 1
fi

# Read the config file, initialising variables
CONFIG_FILE="$HOME/.config/backup/config.json"
CONFIG=$(jq -c . "$CONFIG_FILE")
BW_EMAIL=$(echo "$CONFIG" | jq -r .bitwarden.email_address)
BW_FOLDER_NAME=$(echo "$CONFIG" | jq -r .bitwarden.folder_name)
BW_EXE=$(echo "$CONFIG" | jq -r .bitwarden.cli_executable)
DISK_UNLOCK_BW_ITEM=$(echo "$CONFIG" | jq -r .bitwarden.disk_unlock_item_id)
BACKUP_DISK=$(echo "$CONFIG" | jq -r .backup.device_path)
BACKUP_MOUNT=$(echo "$CONFIG" | jq -r .backup.mount_location)
BACKUP_SOURCE=$(echo "$CONFIG" | jq -r .backup.snapshot_location)
BACKUP_STAGING=$(echo "$CONFIG" | jq -r .backup.staging_location)
RCLONE_DESINATION=$(echo "$CONFIG" | jq -r .rclone.destination)
RCLONE_CONFIG=$(echo "$CONFIG" | jq -r .rclone.config)
PASSPHRASE_LEN=$(echo "$CONFIG" | jq -r .encrypt.passphrase_len)
PASSPHRASE_CHARSET=$(echo "$CONFIG" | jq -r .encrypt.passphrase_charset)

if [ -z ${BW_SESSION+x} ]
then
  LOCAL_SESSION=true
else
  LOCAL_SESSION=false
fi
BACKUP_CLEAR_DEVICE=""

function logout {
  if [ "$LOCAL_SESSION" = true ]
  then
    $BW_EXE logout
  fi
}

# Log in to bit warden, prompting the user for their passphrase and possibly
# 2FA code.
function bw_login {
  if [ "$LOCAL_SESSION" = true ]
  then
    echo "Log in to bitwarden as $BW_EMAIL" > /dev/stderr
    BW_SESSION=$($BW_EXE login --raw "$BW_EMAIL")
    if [ "${BW_SESSION}" = "" ]
    then
      echo "Bitwarden login failed!" > /dev/stderr
      exit 1
    fi
  else
    echo "Found BW session in BW_SESSION, using that" > /dev/stderr
  fi
}

# Generate a random passphrase from /dev/urandom. The passphrase will be
# $PASSPHRASE_LEN characters long, consisting of characters from
# $PASSPHRASE_CHARSET
function generate_passphrase {
  tr -dc "$PASSPHRASE_CHARSET" < /dev/urandom | head -c "$PASSPHRASE_LEN"
}

# Find or create a folder in BitWarden named $BW_FOLDER_NAME. The folder's ID
# will be printed to stdout.
function bw_folder_id {
  local id
  id="$($BW_EXE get folder --session "$BW_SESSION" "$BW_FOLDER_NAME" | jq -r '.id')"
  if [ "$id" = "" ]
  then
    echo "Creating folder '$BW_FOLDER_NAME'..." > /dev/stderr
    id="$(
      $BW_EXE get template --session "$BW_SESSION" folder | \
        jq --arg name "$BW_FOLDER_NAME" \
          '.name=$name' | \
        $BW_EXE encode --session "$BW_SESSION" | \
        $BW_EXE create folder --session "$BW_SESSION" | \
        jq -r '.id'
    )"
  else
    echo "Using existing folder '$BW_FOLDER_NAME'" > /dev/stderr
  fi
  echo "$id"
}

# Store a passphrase to the folder found by `bw_folder_id` in BitWarden.
#
# Parameters:
#   1. The passphrase
#   2. The backup time string, used to name the stored passphrase
function store_passphrase {
  local phrase=$1
  local bk_time=$2
  local name="Backup $bk_time"
  if $BW_EXE get item --quiet --session "$BW_SESSION" "$name"
  then
    echo "Vault item named '$name' already exists!" > /dev/stderr
    exit 1
  fi
  local folder_id
  folder_id=$(bw_folder_id)
  local login
  login="$(
    $BW_EXE get template --session "$BW_SESSION" item.login | \
      jq -c --arg phrase "$phrase" '.username="" | .password=$phrase | .totp=""'
  )"
  local item
  item="$(
    $BW_EXE get template --session "$BW_SESSION" item | \
      jq --arg name "$name" \
        --arg note "Passphrase for gpg encrypted backup taken at $bk_time" \
        --arg folder "$folder_id" \
        --argjson login "$login" \
        '.name=$name | .login=$login | .notes=$note | .folderId=$folder'
  )"
  echo "Creating vault entry named '$name'..." > /dev/stderr
  echo "$item" | $BW_EXE encode --session "$BW_SESSION" | $BW_EXE create item --session $BW_SESSION --quiet
}

# Retrieve a passphrase stored by `store_passphrase`.
#
# Parameters:
#   1. The backup time string
function retrieve_passphrase {
  local phrase_name="Backup $1"
  $BW_EXE get item --session "$BW_SESSION" "$phrase_name" | jq -r .login.password
}

# Compress a backup snapshot to a tarball.
#
# Parameters:
#   1. The snapshot name / backup time string
function compress {
  local name="$1"
  local file="${BACKUP_STAGING}/${name}.tar.gz"
  if [ -f "$file" ]
  then
    echo "Found target compressed file $file, skipping compression." > /dev/stderr
  else
    echo "Compressing to $file..." > /dev/stderr
    tar -zcf "$file" -C "${BACKUP_SOURCE}" "${name}"
  fi
  du -hs "$file" > /dev/stderr
  echo "Testing compressed archive..." > /dev/stderr
  tar xOf "$file" > /dev/null
  echo "$file"
}

# Encrypt a compressed backup tarball using gpg.
#
# Parameters:
#   1. The snapshot name / backup time string
#   2. The backup tarball file
function encrypt {
  local name="$1"
  local input="$2"

  echo "Generating passphrase to bitwarden..." > /dev/stderr
  local pass
  pass=$(generate_passphrase)
  store_passphrase "$pass" "$name"
  echo "Encrypting with passphrase stored in bitwarden as 'Backup $name'..." > /dev/stderr
  gpg --batch --passphrase "$pass" --no-symkey-cache --cipher-algo AES256 --symmetric "$input"
  local output="$input.gpg"
  du -hs "$output" > /dev/stderr
  echo "$output"
}

# Test the encrypted archive by decrypting it using the passphrase from
# BitWarden.
#
# Parameters:
#   1. The snapshot name / backup time string
#   2. The encrypted backup file
function test_encrypted_archive {
  local name="$1"
  local file="$2"
  echo "Testing encrypted archive..." > /dev/stderr
  local pass
  pass=$(retrieve_passphrase "$name")
  gpg --batch --passphrase "$pass" -o /dev/null --decrypt "$file"
}

# Find the name of the most recent backup snapshot.
function find_source_backup {
  local latest
  latest=$(ls -Art ${BACKUP_SOURCE} | tail -n 1)
  du -hs "${BACKUP_SOURCE}/${latest}" > /dev/stderr
  echo "$latest"
}

# Retrieve the backup disk's unlock passphrase from BitWarden.
function backup_disk_unlock_pass {
  echo "Getting drive passphrase from bitwarden..." > /dev/stderr
  local pp
  pp=$($BW_EXE get item --session "$BW_SESSION" "$DISK_UNLOCK_BW_ITEM" | jq -r .login.password)
  echo "$pp"
}

# Unlock the backup disk. Sets the BACKUP_CLEAR_DEVICE variable to the path of
# the clear device.
function unlock_source {
  local unlock_pass
  unlock_pass=$(backup_disk_unlock_pass)
  echo "Unlocking drive..." > /dev/stderr
  local output
  output=$(udisksctl unlock -b "$BACKUP_DISK" --key-file <(echo -n "${unlock_pass}"))
  # udisksctl output is 'Unlocked [raw device] as [clear device].', I need to extract clear device path
  local tail
  tail="${output#Unlocked * as }"
  BACKUP_CLEAR_DEVICE="${tail::-1}"
}

# Mount the unlocked backup device
function mount_source {
  output=$(udisksctl mount -b "$BACKUP_CLEAR_DEVICE")
  local path
  path="${output#Mounted * at }"
  if [ "$BACKUP_MOUNT" = "$path" ]
  then
    echo "Mounted backup drive at $path" > /dev/stderr
  else
    echo "Backup drive mounted at unexpected location $path, expected $BACKUP_MOUNT" > /dev/stderr
    exit 1
  fi
}

# Upload the encrypted backup file, then download it to verify that it was
# uploaded correctly.
#
# Parameters:
#   1. The encrypted backup file
function upload_verify {
  local file="$1"
  echo "Uploading encrypted file..." > /dev/stderr
  rclone --config "$RCLONE_CONFIG" copy "$file" "$RCLONE_DESINATION"
  echo "Verifying uploaded file..." > /dev/stderr
  local remote_file
  remote_file="$RCLONE_DESINATION/$(basename "$file")"
  rclone --config "$RCLONE_CONFIG" cat "$remote_file" | diff - "$file"
}

# Create an on-demand backup using timeshift.
function create_backup {
  timeshift --create --scripted
}

# Unmount the backup drive.
function unmount_source {
  if [ x"${BACKUP_CLEAR_DEVICE}" != "x" ]
  then
    echo "Unmounting source device..." > /dev/stderr
    local attempts=0
    until umount "$BACKUP_CLEAR_DEVICE" || [ $attempts -gt 10 ]
    do
      echo "Unmount failed, trying again in 5s" > /dev/stderr
      attempts=$((attempts+1))
      sleep 5
    done
  fi
}

# Lock the backup drive.
function lock_source {
  if [ x"${BACKUP_CLEAR_DEVICE}" != "x" ]
  then
    echo "Locking source device..." > /dev/stderr
    local attempts=0
    until udisksctl lock -b "$BACKUP_DISK" || [ $attempts -gt 10 ]
    do
      echo "Lock failed, trying again in 5s" > /dev/stderr
      attempts=$((attempts+1))
      sleep 5
    done
  fi
}

# Execute cleanup operations:
#   * Log out of BitWarden
#   * Unmount the backup device
#   * Lock the backup device
# Run on completion of the script via a trap
function cleanup {
  logout || true
  unmount_source || true
  lock_source || true
}

trap cleanup EXIT

bw_login

unlock_source
create_backup
unmount_source
mount_source
LATEST=$(find_source_backup)
COMPRESSED_FILE=$(compress "$LATEST")
ENCRYPTED_FILE=$(encrypt "$LATEST" "$COMPRESSED_FILE")
test_encrypted_archive "$LATEST" "$ENCRYPTED_FILE"
rm -f "$COMPRESSED_FILE"
upload_verify "$ENCRYPTED_FILE"
rm -f "$ENCRYPTED_FILE"

echo "Encrypted file has been uploaded and verified, passphrase is stored in your vault."
