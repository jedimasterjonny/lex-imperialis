# stow

Deploys GNU stow packages from the owner's dots checkout; common and dev
include it for their dotfiles. Consumers set `stow_user`, `stow_user_home` and
`stow_packages` (the dotfile trees), and ensure git is installed. `stow_package`
is the OS package the role installs, through `ansible.builtin.package` — the
name is `stow` on openSUSE and Debian alike, so the one default covers both.

- The clone is bootstrap-only (`update: false`): tracked files are the live
  targets of the deployed symlinks, so refreshing the tree is the
  operator's call.
- Anything non-symlink at a target path — skel files, manual edits — is
  deleted so stow can own it; an existing symlink is a prior deployment
  and stays untouched, keeping the role idempotent.
- Stows with `--no-folding`, so every target is a leaf symlink. A folded
  directory symlink would let the removal above resolve through it and delete
  the real file in the clone; the flag keeps that safety in-repo rather than
  resting on the dots repo's own `.stowrc`.
