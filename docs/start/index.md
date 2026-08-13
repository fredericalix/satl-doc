# Getting started

Four pages, in order. Do not skip the first one: two of its entries need a
reboot or a package install, and finding that out half-way through an install
is worse than reading a table.

1. **[Requirements](requirements.md)** — the checklist before you type
   anything, as *what / why / what happens if it is missing*.
2. **[Install](install.md)** — prepare the host, build, configure, start.
   Including the one trap that catches every stock install.
3. **[Your first container](first-container.md)** — bare host to a container
   serving traffic, with what breaks at each step if you skip it.
4. **[What just happened](what-happened.md)** — a debrief: what `satld`
   created on your machine, and why `satl rm` removed more than you asked.

Everything here is single-node. A single node is a cluster of one, so nothing
you learn is thrown away when you add machines — see
[Clustering](../cluster/index.md) for that.
