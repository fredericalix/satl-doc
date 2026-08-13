```pf title="/etc/pf.conf"
# SatL owns the satl/* anchors and never writes a rule outside them.
# Translation anchors must be declared before any filter rule.
nat-anchor "satl/*"
rdr-anchor "satl/*"
anchor     "satl/*"

# A host with no firewall policy of its own adds exactly one line after them.
pass all
```
