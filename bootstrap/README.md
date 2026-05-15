# Bootstrap

How to turn a fresh openSUSE Tumbleweed install into a working lab box.

## Box prep — manual, one-time, ~5 minutes

All steps run from your local machine. The box just needs a reachable sshd —
if the installer didn't enable one, console in and run `systemctl enable --now sshd`.

1.  Copy `stage1.sh` and your SSH public key onto the box:

    ```sh
    scp bootstrap/stage1.sh ~/.ssh/id_ed25519.pub jonny@scholam:/tmp/
    ```

2.  Run the script remotely (via `sudo`, since it needs root):

    ```sh
    ssh -t jonny@scholam sudo bash /tmp/stage1.sh
    ```

3.  Install your pubkey into `ansible`'s `authorized_keys`. The account
    has no password yet, so jonny's `sudo` does the write — redirection
    happens on the remote side so sudo can still prompt on the tty:

    ```sh
    ssh -t jonny@scholam 'sudo tee -a /home/ansible/.ssh/authorized_keys < /tmp/id_ed25519.pub > /dev/null && rm /tmp/id_ed25519.pub'
    ```

4.  Verify:

    ```sh
    ssh ansible@scholam 'whoami && sudo -n true && echo OK'
    ```

    Expected: prints `ansible`, `OK`.

## Dev loop setup — on-box, one-time, ~1 minute

The `lab-bootstrap` Make target invokes `ansible-playbook` against
`ansible@localhost`, so `jonny` on the box needs ansible in a venv, a key
trusted by `ansible`, and an accepted host key for `localhost`.

1.  From a checkout of this repo, create the venv (installs `ansible-core`
    and the rest of the dev tooling) and put it on `PATH`:

    ```sh
    make setup
    source .venv/bin/activate
    ```

2.  Generate an SSH key for `jonny` if you don't already have one:

    ```sh
    test -f ~/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
    ```

3.  Append `jonny`'s pubkey to `ansible`'s `authorized_keys`:

    ```sh
    sudo tee -a /home/ansible/.ssh/authorized_keys < ~/.ssh/id_ed25519.pub > /dev/null
    ```

4.  Accept the host key so the first run isn't blocked by an interactive prompt:

    ```sh
    ssh -o StrictHostKeyChecking=accept-new ansible@localhost true
    ```

Verify:

```sh
make lab-bootstrap
```

Pass extra `ansible-playbook` flags via `ARGS`, e.g. for a dry run:

```sh
make lab-bootstrap ARGS='--check --diff'
```

## After bootstrap

The playbook configures Incus + libvirt with weekly image-refresh timers and
caches both an Incus `tumbleweed` system-container image and a libvirt
`tumbleweed-base.qcow2`. It is fully idempotent — safe to re-run any time.

The bootstrap adds `jonny` and `ansible` to the `incus-admin` and `libvirt`
groups, but **group membership only takes effect on the next login** — log
out and back in (or `newgrp incus-admin && newgrp libvirt`) before:

```sh
incus list           # should succeed without sudo
virsh list --all     # should succeed without sudo
```
