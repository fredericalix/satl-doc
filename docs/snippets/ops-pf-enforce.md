<!-- Include from pages under docs/use/ only: the links below are relative to
     that directory. -->
!!! warning "Published ports need `pf_mode = "enforce"`"

    The built-in default is `pf_mode = "check"`, which generates the `satl/rdr`
    rules and syntax-checks them without ever loading one. Ports are still
    allocated and still shown by `satl service ls`, and nothing is redirected.
    Set `pf_mode = "enforce"` in [`satld.toml`](../config/satld-toml.md), and
    make sure pf itself is enabled (`sysrc pf_enable=YES`, `service pf start`)
    with the `satl/*` anchors declared in `/etc/pf.conf`.
