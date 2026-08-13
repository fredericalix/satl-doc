!!! info "Manager-only"

    This is cluster state, so it is served by managers. On a worker node the
    same command answers Docker's own refusal, verbatim, with HTTP 503:

    ```
    Error response from daemon: This node is not a swarm manager. Worker nodes
    can't be used to view or modify cluster state. Please run this command on a
    manager node or promote the current node to a manager.
    ```
