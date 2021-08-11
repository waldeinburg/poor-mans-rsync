#!/usr/bin/env bash
# Replacement for "rsync -avuz --delete <folder> <host>:<folder>" when rsync does not exist on server.
# Deleted files are detected and deleted.

set -e

# Not %C as scp -p will not preserve status change. For the same reason we include permissions.
FIND_FILES_FORMAT='%p:%#m:%T@'

function usage_and_exit() {
  echo "Usage: $0 [--dry] [-v|--verbose] [--debug] [--overwrite-all] <src-folder> <host> <dest-folder>"
  exit "${1:-1}"
}

DRY=
VERBOSE=
DEBUG=
OVERWRITE_ALL=
TEMP=$(getopt -o 'v' -l 'dry,verbose,debug,overwrite-all' -- "$@") || usage_and_exit 99
eval set -- "$TEMP"
unset TEMP
while :; do
  case "$1" in
  --dry)
    DRY=1
    shift
    ;;
  -v | --verbose)
    VERBOSE=1
    shift
    ;;
  --debug)
    VERBOSE=1
    DEBUG=1
    shift
    ;;
  --overwrite-all)
    OVERWRITE_ALL=1
    shift
    ;;
  --)
    shift
    break
    ;;
  *)
    echo "Error!" >&2
    exit 1
    ;;
  esac
done
[[ $# -eq 3 ]] || usage_and_exit
SRC=$1
REMOTE_HOST=$2
DEST=$3

deleted_dirs=

function prnt() {
  local msg=$1
  if [[ "$VERBOSE" ]]; then
    echo "$msg"
  fi
}

function dbg() {
  local msg=$1
  if [[ "$DEBUG" ]]; then
    # To stderr; dbg might be used inside function giving output through $().
    echo "$msg" >&2
  fi
}

function ssh_cmd() {
  local cmd=$1
  dbg "Run: $cmd" >&2
  # -n: read from stdin will break read-while loops.
  # shellcheck disable=SC2029
  ssh -n "$REMOTE_HOST" "$cmd"
}

function find_type_in_src() {
  local type=$1
  shift
  # Not "$@"; it must work the same way when put in the ssh command.
  cd "$SRC" && find . -type "$type" "$@" | sort
}

function find_dirs_in_src() {
  find_type_in_src d
}

function find_files_in_src() {
  find_type_in_src f -printf "$FIND_FILES_FORMAT\n"
}

function find_type_in_dest() {
  local type=$1
  shift
  ssh_cmd "cd '$DEST' && find . -type '$type' $* | sort"
}

function find_dirs_in_dest() {
  find_type_in_dest d
}

function find_files_in_dest() {
  find_type_in_dest f -printf "$FIND_FILES_FORMAT"'\\n'
}

function strip_meta() {
  sed -r 's/(.*)(:[0-9.]+){2}$/\1/' <<<"$1"
}

function diff_find() {
  diff <(echo "$1") <(echo "$2") | sed -rn '/^> / { s/> (.*)/\1/; p }'
}

function remove_deleted_dirs_from_list() {
  local list=$1
  local deleted_dirs=$2
  local d

  if [[ "$deleted_dirs" ]]; then
    while read -r d; do
      list=$(grep -Pv "^\Q$d\E/" <<<"$list")
    done <<<"$deleted_dirs"
  fi

  echo "$list"
}

function get_file_line_metadata() {
  local line=$1
  sed -r 's/.*:([0-9]+:[0-9.]+)$/\1/' <<<"$line"
}

function get_files_with_newer_ts() {
  local local_files=$1
  local remote_files=$2
  local lf_line
  local lf_name
  local lf_meta
  local lf_ts
  local lf_ts_sec
  local rf_line
  local rf_meta
  local rf_ts
  local rf_ts_sec
  local lf_perm
  local rf_perm

  if [[ -z "$local_files" ]]; then
    return
  fi

  while read -r lf_line; do
    dbg "lf_line=$lf_line"
    lf_name=${lf_line%:*:*}
    rf_line=$(grep -P "^\Q$lf_name\E:" <<<"$remote_files")
    dbg "rf_line=$rf_line"
    # Not found? Then lf is a new file.
    if [[ -z "$rf_line" ]]; then
      echo "$lf_name"
      continue
    fi
    # I would probably not ever use colons in filenames. But I will not run the risk and use ${lf_line#*:}
    lf_meta=$(get_file_line_metadata "$lf_line")
    rf_meta=$(get_file_line_metadata "$rf_line")
    dbg "lf_meta=$lf_meta"
    dbg "rf_meta=$rf_meta"
    # Compare timestamp second.
    lf_ts=${lf_meta#*:}
    rf_ts=${rf_meta#*:}
    dbg "lf_ts=$lf_ts"
    dbg "rf_ts=$rf_ts"
    lf_ts_sec=${lf_ts%.*}
    rf_ts_sec=${rf_ts%.*}
    dbg "lf_ts_sec=$lf_ts_sec"
    dbg "rf_ts_sec=$rf_ts_sec"
    # Is lf newer second?
    if [[ $lf_ts_sec -gt $rf_ts_sec ]]; then
      echo "$lf_name"
      continue
    fi
    if [[ $lf_ts_sec -lt $rf_ts_sec ]]; then
      echo "Warning: Local file $lf_name is older than remote file." >&2
      continue
    fi
    # Seconds are equal. But do not compare fraction as scp -p will truncate it to 0.
    # Compare permissions.
    lf_perm=${lf_meta%:*}
    rf_perm=${rf_meta%:*}
    dbg "lf_perm=$lf_perm"
    dbg "rf_perm=$rf_perm"
    if [[ "$lf_perm" != "$rf_perm" ]]; then
      echo "$lf_name"
      continue
    fi
    dbg "$lf_name is not updated"
  done <<<"$local_files"
}

function create_directories() {
  dirs=$1

  if [[ -z "$dirs" ]]; then
    return
  fi
  while read -r d; do
    ssh_cmd "mkdir -p '${DEST%/}/$d'"
  done <<<"$dirs"
}

function copy_all() {
  cd "$SRC"
  scp -rp . "$REMOTE_HOST":"$DEST"
}

function copy_files() {
  local files=$1

  if [[ "$files" ]]; then
    cd "$SRC"
    # We could take this in batches for performance. But it would complicate things, and one might
    # as well use --overwrite-all if we have lots of updated files.
    while read -r f; do
      dbg "Copying $f ..."
      scp -p "$f" "$REMOTE_HOST:${DEST%/}/$f"
    done <<<"$files"
  else
    echo "No files to copy."
  fi
}

function delete_from_list() {
  local list=$1
  local name=$2

  if [[ "$list" ]]; then
    echo "Deleting $name ..."
    while read -r item; do
      echo "$item"
      ssh_cmd "cd '$DEST' && rm -r '$item'"
    done <<<"$list"
  else
    echo "No $name to delete."
  fi
}

prnt "Getting local files ..."
local_files_with_ts=$(find_files_in_src)
dbg "$local_files_with_ts"
prnt "Getting remote files ..."
remote_files_with_ts=$(find_files_in_dest)
dbg "$remote_files_with_ts"
prnt "Getting local directories ..."
local_dirs=$(find_dirs_in_src)
dbg "$local_dirs"
prnt "Getting remote directories ..."
remote_dirs=$(find_dirs_in_dest)
dbg "$remote_dirs"

local_files=$(strip_meta "$local_files_with_ts")
dbg "local_files:"
dbg "$local_files"
remote_files=$(strip_meta "$remote_files_with_ts")
dbg "remote_files:"
dbg "$remote_files"
deleted_dirs=$(diff_find "$local_dirs" "$remote_dirs")
dbg "deleted_dirs (pre cleanup):"
dbg "$deleted_dirs"
deleted_files=$(diff_find "$local_files" "$remote_files")
dbg "deleted_files (pre cleanup):"
dbg "$deleted_files"
missing_dirs=$(diff_find "$remote_dirs" "$local_dirs")
dbg "missing_dirs:"
dbg "$missing_dirs"

# Ignore subdirectories of deleted directories.
# Yes, remove $deleted_dirs from $deleted_dirs. The function will iterate over the list, removing
# lines starting with the item followed by slash, thus removing all subdirectories of deleted
# directories.
deleted_dirs=$(remove_deleted_dirs_from_list "$deleted_dirs" "$deleted_dirs")
dbg "deleted_dirs:"
dbg "$deleted_dirs"
# Ignore files in deleted directories.
deleted_files=$(remove_deleted_dirs_from_list "$deleted_files" "$deleted_dirs")
dbg "deleted_files:"
dbg "$deleted_files"

# Skip creating list if we are just overwriting. This will suppress warnings of newer files on
# remote which would be the reason for using --overwrite-all.
if ! [[ "$OVERWRITE_ALL" ]]; then
  dbg "Calculating newer_files ..."
  newer_files=$(get_files_with_newer_ts "$local_files_with_ts" "$remote_files_with_ts")
fi

if [[ "$DRY" ]]; then
  if [[ "$OVERWRITE_ALL" ]]; then
    echo "### WOULD COPY ALL FILES ###"
  else
    echo "### WOULD COPY FILES ###"
    echo "$newer_files"
  fi
  echo "### WOULD DELETE DIRECTORIES ###"
  echo "$deleted_dirs"
  echo "### WOULD DELETE FILES ###"
  echo "$deleted_files"
  exit
fi

if [[ "$OVERWRITE_ALL" ]]; then
  prnt "Copying all files ..."
  copy_all
else
  prnt "Creating missing directories ..."
  create_directories "$missing_dirs"
  prnt "Copying files ..."
  copy_files "$newer_files"
fi

prnt "Deleting removed directories ..."
delete_from_list "$deleted_dirs" 'directories'
prnt "Deleting removed files ..."
delete_from_list "$deleted_files" 'files'
