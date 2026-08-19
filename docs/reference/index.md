# Reference

The narrative chapters explain how something works and what it costs.
These pages state what it *is*: exact defaults, exact port numbers, exact key names, the vocabulary, and an explicit list of what SatL does not do.
This is where you come to check a value rather than to understand a mechanism, and the two are kept apart on purpose — a page that argues a case and a page you grep for a number want different shapes.

Two of these pages are held to their sources mechanically rather than by review.
The [`satld.toml`](satld-toml.md) reference is compared against the daemon's own configuration struct on every build, in both directions: a key the daemon accepts cannot go undocumented, and a key documented here cannot fail to exist.
The [command line](cli/index.md) pages are generated from the binaries' own `--help`, one page per verb, each stamped with the SatL version it was harvested from — so what you read is what your `satl` accepts, not a recollection of what it accepted once.

## The pages

- **[`satld.toml`](satld-toml.md)** — every key the daemon accepts, one heading each, with its type, its default, what an unset value means, and what is checked at load time rather than later.
  The decisions that go with them are in [Configuration](../config/index.md).
- **[Ports and firewall](ports.md)** — 2377, 2378, 4789, the encrypted-overlay range and ESP, the API socket, and the `pf` contract: the three anchor lines SatL needs and what it writes inside them.
- **[Defaults and constants](defaults.md)** — the timings and limits that govern task behaviour, rolling updates, cluster liveness, networking and security, plus the things that have no default because they have no limit.
- **[Command line](cli/index.md)** — `satl` and `satld`, verb by verb, with the flags, arguments, defaults and environment variables each one accepts.
- **[Glossary](glossary.md)** — the words this site uses for nodes and roles, workloads, state, networking and security, and which Docker word each one corresponds to.
- **[What SatL does not do](out-of-scope.md)** — the deliberate absences, with the reason for each and what to do instead.
  Read alongside [Project status](../about/status.md), which covers what is merely *not built yet*; this page is about what is not coming.
