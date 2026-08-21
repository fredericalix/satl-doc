# Metrics

SatL serves a Prometheus endpoint.
It is **off by default**, on its own listener, and unauthenticated, dockerd's exact posture, flag included:

```toml
# /usr/local/etc/satl/satld.toml
metrics_addr = "10.2.0.4:9323"
```

or `--metrics-addr` on the `satld` command line, which wins over the file.
With neither set, no listener exists at all.

!!! warning "Unauthenticated by design: bind it somewhere private"

    This mirrors dockerd, whose `--metrics-addr` serves anyone who can reach it.
    The scrape reveals the cluster's shape: service and task counts, raft state, and, with resource accounting on, per-task memory and CPU.
    Bind a management address the Prometheus server can reach and nothing else.

    The endpoint is deliberately not a route on the REST API: that router is
    version-rewritten and bound to a unix socket, neither of which a
    Prometheus server can scrape.

## What is exported

Where dockerd defines a series SatL has an equivalent of, SatL emits **Docker's
exact name**, so an off-the-shelf Docker dashboard renders unchanged:

- `engine_daemon_container_states_containers` (by state), `engine_daemon_engine_info`,
  `engine_daemon_engine_cpus_cpus`, `engine_daemon_engine_memory_bytes`;
- `engine_daemon_health_checks_total` and `engine_daemon_health_checks_failed_total`;
- the `http_requests_total` API histogram (method and code labels), as Docker's.

Everything SatL-specific is `satl_*`: raft role, term, leader and applied
index, store counts (`satl_services`, `satl_tasks`), reconcile passes,
dispatcher sessions, external-command failures, and the node certificate's
expiry (`satl_node_certificate_not_after_timestamp_seconds`, the one to alert
on long before it matters, though renewal is automatic).

## Per-container usage needs racct

`satl_container_memory_usage_bytes` and `satl_container_cpu_time_seconds` are read from `rctl` on a 20 s collector cadence, one series per running task.
They exist only when the kernel accounting is on, the same `kern.racct.enable=1` [resource limits](resource-limits.md) need.
With it off, no `rctl` process is ever spawned and the series are simply absent: the same degradation `--memory` accepts, and for the same reason.

## A minimal scrape config

```yaml
scrape_configs:
  - job_name: satl
    static_configs:
      - targets: ["10.2.0.4:9323", "10.2.0.5:9323", "10.2.0.6:9323"]
```

Scrape every manager; a worker serves the same listener but holds no raft and no store, so its cluster series read `none`/0 and only the node-local ones are meaningful there.
`promtool check metrics` passes on the output.
