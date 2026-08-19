```sh
# kern.racct.enable is a boot-time tunable: it cannot be switched on at
# runtime, and without it `--memory` and `--cpus` are accepted and never
# enforced. sysrc(8) refuses dotted names, so the line is appended directly --
# through tee(1) rather than `>>`, because a redirection is opened by your
# shell, as you, before doas(1) or sudo(8) ever runs. Run as root, or put the
# privilege on the tee: `echo ... | doas tee -a /boot/loader.conf`.
echo 'kern.racct.enable=1' | tee -a /boot/loader.conf

# Optional, and only if you will use overlay networks: if_vxlan is not in the
# GENERIC kernel. satld runs `kldload -n if_vxlan` itself before it creates the
# first tunnel, so this only moves the failure from the first overlay network
# to boot time -- which is where you want to find it.
echo 'if_vxlan_load="YES"' | tee -a /boot/loader.conf
```
