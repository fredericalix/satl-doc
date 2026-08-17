# Images

Pulling, storing, resolving — and building — OCI images on ZFS.

SatL treats an image as content-addressed blobs plus a layer chain, and the layer chain *is* ZFS: each applied layer is a dataset cloned from the previous one's snapshot, so two images sharing a base share the datasets for that base.
`zfs list -r zroot/satl/layers` is the honest inventory of what images cost a node.

The day-to-day surface:

- **[Images](../use/images.md)** — pulling, platform selection
  (`freebsd/*` preferred, `linux/amd64` under the linuxulator), registries and
  authentication, where the bytes go, and what reclaims them.
- **[`satl build`](../use/images.md#satl-build)** — building FreeBSD images
  from a `Satlfile`: a base userland plus `pkg` packages, repacked as OCI.
- **[`satl pull`](../reference/cli/pull.md)** and
  **[`satl images`](../reference/cli/images.md)** in the CLI reference, and
  [`satl build`](../reference/cli/build.md) alongside them.
- **[Reclaiming space](../use/reclaiming-space.md)** — image reclamation is
  manual and node-local; that page is the one to read before a pool fills.
