# dropbox_scripts

This repository contains a script (`sync_gitignores_dropbox.sh`) which, when run, will tell Dropbox to ignore all directories that are ignored by Git.

The following environment variables can be configured to change behavior:
- __DRY_RUN__ (true|false) - just print what would be done
- __FORCE__ (true|false) - don't ask for confirmation
- __DROPBOX_ROOT__ (an existing directory) - the root Dropbox directory
- __BACKUP_DIR_ROOT__ (an existing directory) - the directory in which temporary files will be stored in case something goes wrong

E.g. to do a dry-run: `env DRY_RUN=true bash sync_gitignores_dropbox.sh`

It was tested on Ubuntu 19.10, Bash 5.0.3, Dropbox 84.4.170 (2019.02.14 CLI), and Git version 2.20.1. As much as possible, I tried to make it portable, but I have not tested it elsewhere or on different versions, and I am sure that there will be some issues.

# Known Issues

## OS X
- `dropbox` CLI not available
- `sed` options 
