#!/bin/bash

set -eu

# Allow the following variables to be overridden by the environment
# DRY_RUN (true|false) - just print what would be done
# FORCE (true|false) - don't ask for confirmation
# DROPBOX_ROOT (an existing directory) - the root Dropbox directory
# BACKUP_DIR_ROOT (an existing directory) - the directory in which
#     temporary files will be stored in case something goes wrong

# DRY_RUN
if [ -z "${DRY_RUN+u}" ]
then
    DRY_RUN='false'
elif [[ ! "$DRY_RUN" =~ ^(true|false)$ ]]
then
    echo "DRY_RUN ($DRY_RUN) must be true or false"
    exit 1
fi

# FORCE
if [ -z "${FORCE+u}" ]
then
    FORCE='false'
elif [[ ! "$FORCE" =~ ^(true|false)$ ]]
then
    echo "FORCE ($FORCE) must be true or false"
    exit 2
fi

# DROPBOX_ROOT
if [ -z "${DROPBOX_ROOT+u}" ]
then
    DROPBOX_ROOT="$HOME/Dropbox"
fi

if [ ! -d "$DROPBOX_ROOT" ]
then
    echo "DROPBOX_ROOT ($DROPBOX_ROOT) does not exist"
    exit 3
fi

# BACKUP_DIR_ROOT
if [ -z "${BACKUP_DIR_ROOT+u}" ]
then
    BACKUP_DIR_ROOT="$HOME/.dropbox_sync_excludes_backup"
    mkdir -p "$BACKUP_DIR_ROOT"
elif [ ! -d "$BACKUP_DIR_ROOT" ]
then
    echo "BACKUP_DIR_ROOT ($BACKUP_DIR_ROOT) does not exist"
    exit 4
fi

exit_with_backup_dir() {
    echo "$1"
    echo "Please manually restore using ${2}/.in_flight"
    echo "Once complete, please delete the backup directory ($2) and re-run"
    exit 5
}

# If an existing backup exists (and wasn't cleaned up), that means that
# the exit trap did not execute fully. This requires manual correction
if [ $(ls "$BACKUP_DIR_ROOT" | wc -l) -gt 0 ]
then
    existing_backup_dir="${BACKUP_DIR_ROOT}/$(ls $BACKUP_DIR_ROOT | head -n 1)"
    exit_with_backup_dir "An in-progress backup exists" "$existing_backup_dir"
fi

BACKUP_DIR="${BACKUP_DIR_ROOT}/$(date +%Y-%m-%d-%H)-$(uuidgen)"
mkdir -p "$BACKUP_DIR"
echo "Using BACKUP_DIR ($BACKUP_DIR)"

# Since adding an exclusion to Dropbox tends to (though not always) delete
# the target file/directory, we make a backup of the directory (1), then call
# Dropbox to add the exclusion (2), then move the directory back (3).
# IN_FLIGHT_PATH tracks paths for which (1) has been executed but not (3)
# so that we can automatically recover in the event of a failure
IN_FLIGHT_PATH=''

on_exit() {
    exit_res=$?

    if [ "$exit_res" == 0 -a "$IN_FLIGHT_PATH" == '' ]
    then
        echo "Run completed successfully"
        rm -rf "$BACKUP_DIR"
    else
        if [ "$IN_FLIGHT_PATH" != '' ]
        then
            # If a path was in flight and is no longer present in Dropbox,
            # we copy it back
            if [ ! -d "${DROPBOX_ROOT}/${IN_FLIGHT_PATH}" ]
            then
                echo "Cleaning up in-flight path (${DROPBOX_ROOT}/$IN_FLIGHT_PATH)"
                cp -r \
                   "${BACKUP_DIR}/${IN_FLIGHT_PATH}" \
                   "${DROPBOX_ROOT}/${IN_FLIGHT_PATH}" || \
                    exit_with_backup_dir \
                        "Failed to restore ${DROPBOX_ROOT}/$IN_FLIGHT_PATH" \
                        "$BACKUP_DIR"
            fi
        fi
        echo "Run failed"
        rm -rf "$BACKUP_DIR"
        if [ "$exit_res" == 0 ]
        then
            exit 6
        else
            exit $exit_res
        fi
    fi
}

trap on_exit EXIT

exclude() {
    abs_path="$1"
    rel_path=$(realpath --relative-to="$DROPBOX_ROOT" "$abs_path")
    basename_=$(basename "$abs_path")
    in_flight_file="${BACKUP_DIR}/.in_flight"

    echo "Ignoring ${abs_path}"

    if [ "$DRY_RUN" == 'false' ]
    then
        cmd=eval
    else
        cmd=echo
    fi

    $cmd mkdir -p $(dirname "${BACKUP_DIR}/${rel_path}")
    $cmd cp -r "${abs_path}" "${BACKUP_DIR}/${rel_path}"

    # Keep track of in flight path both in a variable so that we
    # can clean up on exit, and in a file so that if something goes
    # terribly wrong (e.g. the exit trap also fails) data can be
    # manually recovered
    echo "ORIGINAL: ${DROPBOX_ROOT}/${rel_path}" > "$in_flight_file"
    echo "BACKUP: ${BACKUP_DIR}/${rel_path}" >> "$in_flight_file"
    IN_FLIGHT_PATH="${rel_path}"

    $cmd dropbox exclude add "${abs_path}"
    $cmd rm -rf "${abs_path}"
    $cmd mv "${BACKUP_DIR}/${rel_path}" "${abs_path}"

    IN_FLIGHT_PATH=''
    rm -f "$in_flight_file"
}

get_current_exclusions() {
    # Get current list of Dropbox exclusions, which return
    # paths relative to the current directory, so it's easiest
    # for the current directory to be '/'
    cd / && dropbox exclude list \
            | grep -v 'No directories are being ignored.\|Excluded:' || true
}

to_ignore=''
already_ignored=''

current_exclusions=$(get_current_exclusions)

for git_path in $(find "$DROPBOX_ROOT" -type d -name .git)
do
    git_dir=$(dirname "$git_path")
    pushd "$git_dir" 2>&1 > /dev/null
    while read -r ignored_path
    do
        # Only exclude directories
        if [ -d "${git_dir}/${ignored_path}" ]
        then
            abs_path=$(readlink -e "${git_dir}/${ignored_path}")
            if [ -z $(echo "$abs_path" \
                          | grep -iF "$current_exclusions" || true) ]
            then
                to_ignore="${to_ignore}\n${abs_path}"
            else
                already_ignored="${already_ignored}\n${abs_path}"
            fi
        fi
    done < <(git status --ignored -s | egrep '^!! ' | sed -r 's/!! (.*)$/\1/')
    popd 2>&1 > /dev/null
done

# Nested Git directories can cause duplicates to be reported,
# and we potentially appended an extra newline, so clean those up
to_ignore=$(echo -e "$to_ignore" | sort | uniq | egrep -v '^$' || true)
already_ignored=$(echo -e "$already_ignored" | sort | uniq | egrep -v '^$' || true)

echo -e "ALREADY IGNORED\n===============\n${already_ignored}\n"
echo -e "TO IGNORE\n=========\n${to_ignore}\n"

if [ -z "$to_ignore" ]
then
    echo "Nothing to ignore"
    exit 0
fi

if [ "$FORCE" == 'true' ]
then
    user_confirmation='y'
else
    read -p \
         'Continue? This requires temporarily moving each directory to be ignored (y/n): ' \
         user_confirmation
fi

if [[ "$user_confirmation" =~ ^(y|Y|yes|Yes|YES)$ ]]
then
    while read -r abs_path
    do
        exclude "$abs_path"
        echo ''
    done < <(echo -e "$to_ignore")
fi
