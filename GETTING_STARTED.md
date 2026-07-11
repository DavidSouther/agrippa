# Getting Started

This covers local development on macOS against the [K3d] Development environment described in
[`README.md`](./README.md) and [`ARCHITECTURE.html`](./ARCHITECTURE.html) — the same Helm charts
and manifests as Production, running as k3s in Docker instead of on cloud VMs.

## Prerequisites

Mise manages all tools, so it and docker are only ambient dependencies.
Install via [Homebrew](https://brew.sh/):

```bash
brew install docker mise
```

- **Mise** — dev environment task runner, including build in tool installation
- **Docker** — k3d creates k3s clusters as Docker containers, so a running Docker daemon is
  required. Docker Desktop is the common choice on macOS; Colima or OrbStack work too as long as
  `docker info` succeeds.

### Docker resource allocation

k3s plus a handful of platform pods needs more than Docker Desktop's older defaults. In
Docker Desktop, go to **Settings > Resources** and allocate at least **4 CPUs** and **8GB of
memory** to get the preflight check and an early, partial build running. If you're bringing up
the **complete** platform (all ten feature-steps: Istio, cert-manager, metallb, Postgres, Valkey,
Keycloak, Forgejo, Flagsmith, and the full Grafana LGTM observability stack, alongside the
workloads), budget more: live steady-state memory usage on a fully-built `agrippa-dev` cluster
measures around **9.5GB with zero burst headroom** (see
`docs/runbooks/capacity-and-resource-pressure.md` for the live baseline and how to check your own
node's numbers), so **6 CPUs and 12GB** is a safer floor and **8 CPUs and 16GB** is comfortable.
If you've set these differently, override the preflight check's expectations with
`MIN_DOCKER_CPU` and `MIN_DOCKER_MEM_GB` (see below).

Apple Silicon and Intel Macs both work — k3d and the k3s node image are multi-arch, no extra
configuration needed.

## Preflight check

Once the prerequisites are installed, confirm the machine can actually run k3d — not just that the
binaries exist, but that Docker is reachable, sized adequately, and can stand up and tear down a
real cluster:

```bash
bats tests/preflight.bats
```

The last two tests create and delete a throwaway cluster (`agrippa-preflight`). On a first run,
Docker needs to pull the k3s node image, so expect this to take a minute or two; subsequent runs
are faster. If it's interrupted, `k3d cluster delete agrippa-preflight` cleans up manually.

To use a different minimum resource bar or cluster name:

```bash
MIN_DOCKER_CPU=6 MIN_DOCKER_MEM_GB=12 bats tests/preflight.bats
```

### Troubleshooting

- **`docker daemon is running and reachable` fails** — Docker Desktop (or your Docker alternative)
  isn't running. Start it and re-run.
- **`k3d can create a cluster` fails or times out** — check Docker's resource allocation first
  (above), then check nothing else is bound to k3d's default ports, then check
  `k3d cluster create agrippa-preflight` by hand for the actual error.
- **A cluster named `agrippa-preflight` is left over from a previous failed run** —
  `k3d cluster delete agrippa-preflight` before re-running the suite.

## Next steps

Once the preflight check is green, see `DEVELOPMENT.md` for the full testing conventions
(`kubeconform`, `helm-unittest`, `SLOs`, `probers`) this repo uses once there's an actual
platform component to build against.

[K3d]: https://k3d.io/
