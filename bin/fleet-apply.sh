#!/usr/bin/env bash
# Apply the fleet, converging the remote hosts at once.
#
# playbooks/site.yml is four single-host plays, so ansible's forks never come
# into it and a run costs the sum of all four — ~11 minutes, of which the
# controller spends 77% idle on serial SSH round trips, the tunnelled host worst
# of all: it is a WAN round trip away. Sharding that same playbook by host with
# --limit converges the remote hosts concurrently instead, taking ~4 minutes off
# a full apply, and leaves site.yml the one declaration of what the fleet is and
# what each host runs. Measured: the three remote hosts cost 307s together
# against 557s in series, and none is slower for the other two running beside it.
#
# this_host goes last, exactly as site.yml imports it last: it is the control
# host, and a self-apply must not run beside the reconcile it is part of.
#
# One deliberate difference from site.yml. Ansible aborts a run when a play loses
# every host, so a host that could not converge took every play imported after it
# with it — which is what quietly stopped scholam converging whenever an earlier
# host was broken. Here every host is attempted; the run still exits non-zero, so
# arbites withholds last_applied exactly as before.
#
# Arguments are passed through to each ansible-playbook (--check, --diff,
# --vault-password-file, ...). Needs ansible on PATH — the venv's.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

playbook=playbooks/site.yml
# Applied last: the inventory's own name for scholam, the control host.
control_host=this_host

# Read from the inventory, so a host joining the fleet needs no edit here. A host
# in the inventory but not yet in site.yml matches no play and costs a no-op.
mapfile -t fleet < <(ansible all --list-hosts | awk 'NR > 1 {print $1}')
if [ ${#fleet[@]} -eq 0 ]; then
    echo "fleet-apply.sh: no hosts in the inventory" >&2
    exit 1
fi

remote=()
for host in "${fleet[@]}"; do
    [ "$host" = "$control_host" ] || remote+=("$host")
done
# The control host is applied by name rather than by what is left over, so a
# rename that stops matching fails here instead of silently applying it twice.
if [ ${#remote[@]} -eq ${#fleet[@]} ]; then
    echo "fleet-apply.sh: $control_host is not in the inventory" >&2
    exit 1
fi

# Prefix each host's output so concurrent plays stay attributable, in a terminal
# and in arbites's journal alike; blank lines are left bare as separators.
# pipefail inside the subshell, so the prefixing sed cannot mask ansible's status.
apply_host() {
    local host=$1
    shift
    (
        set -o pipefail
        ansible-playbook "$@" --limit "$host" "$playbook" 2>&1 \
            | sed -u "/./s/^/[$host] /"
    )
}

rc=0
failed=()
pids=()
for host in "${remote[@]}"; do
    apply_host "$host" "$@" &
    pids+=("$!")
done
for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || { rc=1; failed+=("${remote[$i]}"); }
done

apply_host "$control_host" "$@" || { rc=1; failed+=("$control_host"); }

if [ "$rc" -ne 0 ]; then
    echo "fleet-apply.sh: failed on ${failed[*]}" >&2
fi
exit "$rc"
