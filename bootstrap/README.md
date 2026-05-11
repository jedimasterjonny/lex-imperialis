# Bootstrap

How to turn a fresh openSUSE Tumbleweed install into a working lab box.

## Stage 1 — manual, one-time, ~5 minutes

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
