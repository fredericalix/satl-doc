<!-- Include from pages one directory under docs/ (start/, use/, ...): the
     links below are relative to that directory. -->
!!! warning "A built image lands in this node's store only"

    There is no cluster-wide image distribution, and the scheduler has no image-locality filter: it places a replica on any node that passes availability, resources, constraints, platform and ports, whether or not that node has the image.
    A loopback registry does not help; `127.0.0.1:5000` is a *different* registry on every node.

    So for a service that may run on more than one node, one of these is not optional:

    - **build on every node it may run on**: same context, same `satl build` command; or
    - **push to a registry every node can reach**, with `satl build --push -t registry.example.com/apps/web:1` or [`satl push`](../reference/cli/push.md#satl-push) on an image already built, and use *that* reference in the service.

    Skipping it does not fail cleanly on a node with no registry at all; the task retries the pull forever and the service sits at `0/3`.
    [Why that failure is silent](../use/images.md#image-locality) is worth reading once.
