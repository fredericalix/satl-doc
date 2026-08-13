```toml title="/usr/local/etc/satl/satld.toml"
# Every key is optional and a missing file means all defaults. These are the
# only two an ordinary first install has any reason to set.

# Load the satl/* pf anchors. The built-in default is "check", which generates
# the rules and syntax-checks them without ever loading one -- so published
# ports are allocated, shown by `satl ps`, and never redirected.
pf_mode = "enforce"

# Only if your pool is not named `zroot`. The dataset must already exist.
#zfs_root = "tank/satl"
```
