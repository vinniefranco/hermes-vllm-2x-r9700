#!/bin/sh
set -e

# Host key lives on a bind mount (configs/workbench/ssh/hostkeys) so the
# workbench keeps its SSH identity across image rebuilds — the gateway pins it
# via StrictHostKeyChecking=accept-new, and a changed key would hard-fail every
# agent command until known_hosts is cleaned up.
if [ ! -f /etc/ssh/hostkeys/ssh_host_ed25519_key ]; then
    ssh-keygen -t ed25519 -N "" -f /etc/ssh/hostkeys/ssh_host_ed25519_key
fi

exec /usr/sbin/sshd -D -e
