# stow

Deploys GNU stow packages from the owner's dots checkout; common and dev
include it for their dotfiles. Consumers set `stow_user`, `stow_user_home`
and `stow_packages`, and ensure git is installed.

- The clone is bootstrap-only (`update: false`): tracked files are the live
  targets of the deployed symlinks, so refreshing the tree is the
  operator's call.
- Anything non-symlink at a target path — skel files, manual edits — is
  deleted so stow can own it; an existing symlink is a prior deployment
  and stays untouched, keeping the role idempotent.
