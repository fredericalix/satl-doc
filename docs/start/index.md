# Getting started

An hour, give or take, from a bare FreeBSD host to a container serving traffic —
and the pages below are in the order that hour actually happens. Do not skip the
first one: two of its entries need a reboot or a package install, and finding
that out half-way through is worse than reading a table.

1. **[Requirements](requirements.md)** — the checklist before you type
   anything, as *what / why / what happens if it is missing*.
2. **[Install](install.md)** — prepare the host, install the package, configure,
   start. Including the one trap that catches every stock install.
3. **[Your first container](first-container.md)** — bare host to a container
   serving traffic, with what breaks at each step if you skip it.
4. **[What just happened](what-happened.md)** — a debrief: what `satld`
   created on your machine, and why `satl rm` removed more than you asked.
5. **[A real application](app-node-mariadb.md)** — Node.js and MariaDB, a
   volume, a healthcheck and a private network, end to end. This is the page to
   send someone who asks what SatL is like to use.

Everything here is single-node. A single node is a cluster of one, so nothing
you learn is thrown away when you add machines — see
[Clustering](../cluster/index.md) for that.
