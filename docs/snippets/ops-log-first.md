<!-- Include from pages under docs/use/ only: the links below are relative to
     that directory. -->
!!! tip "The CLI shows the summary; the log shows the cause"

    An error from `satl` tells you what did not happen.
    `/var/log/messages` tells you which `zfs`, `ifconfig`, `pfctl` or `ocijail` command failed and what it printed.
    Read both, in that order:

    ```sh
    sudo grep -a satld /var/log/messages | tail -50
    ```

    `grep -a` is not optional — see [Reading a log line](../config/logging.md).
