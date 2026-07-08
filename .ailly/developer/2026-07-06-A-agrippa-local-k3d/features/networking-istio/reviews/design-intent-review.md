# Intent Review — Networking (Istio ambient + Gateway API + cert-manager + metallb)

> Cold-dispatch intent review of the Design-phase artifact
> `features/networking-istio/design.md` and its feature test
> `tests/networking.bats`, run at the design draft gate on **2026-07-08**.
>
> Intent review works **backward** from the original request through the
> accumulated phase artifacts, posing *falsifiable* questions where the designed
> behavior may have drifted from what the project actually wants. It **never
> clears** the draft gate and applies **no edits**. Each entry is left **OPEN**
> for a separately dispatched reviewer (or the human) to answer; a resolution is
> an answer to the question, not this reviewer's edit.
>
> **Anchors used.** Feature request (verbatim, from `research.md` § Topic and
> Intent): *"Feature 3: Networking (Istio + cert-manager)…"* plus the dispatched
> open question about metallb's scope. Project-level intent: the **parity model**
> ("the same Helm charts and manifests that production runs, driven by the same
> GitOps spine" — project `design.md` § Purpose), **reproducibility** ("clones the
> repo on a macOS laptop, runs the mise bootstrap, and gets a running local
> platform"; cluster-core `design.md`: "the same working substrate on any machine
> with one command"), `ROUTING.md`'s host-based / per-host blast-radius policy,
> and `DEVELOPMENT.md`'s conventions. Categories per the intent-review ability:
> Research gap · Design assumption · Plan scope · Implementation surprise.

---

## 2026-07-08 — Q1: Is the ArgoCD control-plane UI the right reachability proof for a workload contract? [Design assumption] — OPEN

**Question (falsifiable).** As designed, the feature test proves the shared
Gateway/HTTPRoute/hostname/TLS contract by routing `argocd.127.0.0.1.nip.io` to
the in-cluster `argocd-server`. The parent design's Shared Contracts and resolved
item 6 name that contract against three **prod-mirror workload** hosts
(`davidsouther.com.127.0.0.1.nip.io`, `trips.davidsouther.com.127.0.0.1.nip.io`,
`dashboard.davidsouther.com.127.0.0.1.nip.io`), and `ARCHITECTURE.html` § S8 puts
the ArgoCD UI behind **Tier-1 Cloudflare Access** in production, not on the public
workload path. Does proving the contract against a control-plane service that (a)
is none of the three named hosts, (b) forces `argocd-server` into
`server.insecure: "true"` — a **second** mutation of Feature 2's cleared
`apps/platform/argocd/` config — to route to its `:80`, and (c) is edge-gated in
prod, faithfully exercise the **same** contract Feature 9's workloads consume?

**Assumption challenged.** That ArgoCD is the "zero new-workload cost" *right*
choice (design § Alternatives rejects a throwaway backend on exactly this ground).
The zero-cost framing omits the induced `server.insecure` cross-step patch and the
parity mismatch (insecure, ungated ArgoCD locally vs Tier-1-gated ArgoCD in prod);
a throwaway static backend on one of the three named hosts would incur neither.

**What a resolution looks like.** Either confirm ArgoCD is genuinely
representative (the insecure-mode patch is acceptable, the host-name divergence is
immaterial, the contract is workload-agnostic) — or move the proof to a minimal
static backend on one of the three named mirror hosts, so the step exercises a
public workload route with no control-plane security mutation. A reviewer weighs
the induced Feature-2 mutation and the prod Tier-1 posture against the
"already-exists" saving.

---

## 2026-07-08 — Q2: Does one shared append-only certificate honor ROUTING.md's per-host blast-radius intent? [Design assumption] — OPEN

**Question (falsifiable).** As designed, there is **one** `agrippa-gateway-tls`
`Certificate` whose `dnsNames` every later UI feature-step edits ("later UI
features append their host — a one-line edit to this single file"). `ROUTING.md`
§3 fixes host-based routing precisely because "each subdomain is its own
HTTPRoute, independently owned … a bad edit breaks only that host, keeping blast
radius small." Does a single shared certificate that Auth, Observability, and
Workloads all append to preserve that per-host independent-ownership / small-blast-
radius intent — or does it reintroduce a **shared-mutable object**: one file that
the parallel band (Features 5–8 run concurrently per `plan.md`) all edit, where a
bad SAN edit or a cert reissue affects **every** host's TLS at once and creates
GitOps merge contention the host-based model was meant to avoid?

**Assumption challenged.** That "no single wildcard covers the multi-label hosts"
(true, per `ROUTING.md` §2) implies "**one** shared explicit-SAN cert" (does not
follow). Gateway API listeners accept multiple `certificateRefs` selected by SNI,
so per-feature `Certificate`/Secret pairs are feasible and keep each host's cert
independently owned. Relatedly: is `allowedRoutes.namespaces.from: All` (any
namespace may attach a route to the shared listener) the intended trust model, or
does the same per-host least-trust intent favor a namespace `Selector`?

**What a resolution looks like.** Confirm the shared-append cert is intended
(single-operator scale makes the coupling acceptable and the append is trivial), or
adopt per-feature `Certificate`s each contributing its own Secret to the listener
(or its own listener), and decide `from: All` vs a sanctioned-namespace selector.
A reviewer answers by weighing parallel-merge contention and cross-host blast
radius against the convenience of one file.

---

## 2026-07-08 — Q3: Do committed machine-specific IPs violate the one-command-any-machine reproducibility intent? [Design assumption] — OPEN

**Question (falsifiable).** As designed, `spec.externalIPs: ["172.18.0.3"]` (the
node IP) and the metallb pool `172.18.255.200-172.18.255.250` are committed
**literals** in a git-tracked, ArgoCD-reconciled `core/overlays/dev` manifest, with
a manual `docker inspect` / `docker network inspect` re-derivation note. The
project's stated intent is reproducibility: "clones the repo on a macOS laptop,
runs the mise bootstrap, and gets a running local platform" (project `design.md`),
"the same working substrate on any machine with one command" (cluster-core
`design.md`). Docker assigns the `k3d-agrippa-dev` network subnet from its pool
based on pre-existing networks, and the node IP is assigned per cluster-create — so
on a **different** operator's machine, or after any `cluster:down`/`up`, these
literals can be wrong and the request path silently fails. Does committing them as
defaults align with the one-command-any-machine journey, or does it break the
documented journey for any operator whose Docker network is not `172.18.0.0/16`?

**Assumption challenged.** The design's rationale "acceptable because the cluster
is recreated infrequently and the edit is a one-line reversible seam." That
reasoning weighs the **owner's** long-lived cluster, not the second-operator clone
the project Purpose promises; it also imports a manual step the "one command"
intent is meant to eliminate.

**What a resolution looks like.** Confirm the committed-literal-plus-manual-note is
acceptable (this is effectively single-operator and the journey tolerates one
derive step), or move IP derivation into the build/bootstrap path — a `mise` task
or kustomize component that patches the value from `docker network inspect` /
`docker inspect` at apply time — so the GitOps manifest carries no machine-specific
literal. (The design lists this as an Open Artifact Decision, but the
reproducibility/parity angle is not weighed there; that is the gap this question
surfaces.)

---

## 2026-07-08 — Q4: Is mutating Feature 2's cleared repo-server config within this feature-step's recorded scope? [Plan scope] — OPEN

**Question (falsifiable).** As designed, this feature edits
`apps/platform/argocd/kustomization.yaml` — a Feature 2 (`gitops-argocd`) artifact
— to append `--enable-helm` to the `argocd-cm` `kustomize.buildOptions`, a change
**forced** by choosing the `helmCharts:` inflation composition. `plan.md`'s
Feature 3 scope names "Istio ambient + Gateway API + cert-manager"; it does not
record touching the repo-server's build options. Feature 2's cleared design set
that field for **KSOPS** only. Is mutating Feature 2's cleared repo-server wiring
inside **this** feature-step's recorded scope — or does the composition choice
(which the design's own Alternatives shows is avoidable: the nested app-of-apps
runner-up needs **no** `--enable-helm`) reach into a cleared sibling artifact and
change what Feature 2's `bootstrap` / `gitops.bats` covers?

**Assumption challenged.** That `--enable-helm` is merely "the one repo-server
wiring change the composition needs" and is in-scope by parallel to the KSOPS
flags. The parallel is real, but the KSOPS flag was Feature 2's **own** decision
inside Feature 2; this is Feature 3 reaching back into Feature 2's file to enable a
composition Feature 3 chose.

**What a resolution looks like.** Either sanction the cross-step touch (it lands
where `bootstrap` applies it, avoids a first-sync chicken-and-egg, is trivially
reversible, and the research flagged it in Resolved item 2) — or prefer the
composition that touches no cleared sibling (nested per-component app-of-apps with
native ArgoCD Helm sources), keeping each feature's file-blast-radius to its own
layer. A reviewer weighs the per-resource sync-wave hardness `helmCharts:` buys
against the sibling-artifact boundary it crosses.

---

## 2026-07-08 — Q5: Does the feature test encode the shared CONTRACT, or one reachability instance? [Design assumption] — OPEN

**Question (falsifiable).** The load-bearing deliverable is a **shared** contract
"every later UI feature-step consumes" by appending its host and attaching an
HTTPRoute. The test asserts: `core` Synced/Healthy, a 2xx/3xx from one host, and
the issuer CN. It does **not** assert that a metallb LoadBalancer IP was assigned
(User Journey step 2 claims it as a design guarantee), that the Gateway reached
`Programmed`, that the listener accepts routes (`AttachedRoutes`), or that
host-based routing actually discriminates (a 2xx to the single wired host does not
prove a second host would route independently). Does one host's reachability +
issuer sufficiently encode "a shared Gateway later features can append to," or does
the contract's **sharing/append mechanism** go unverified at the very step that
owns it, deferred implicitly to Feature 9?

**Assumption challenged.** That proving one binding proves the contract. There is
an inherent limit — only one consumer (`argocd`) exists now, so the append-of-a-
second-host cannot be directly exercised here — but the step could still assert the
shared substrate is *ready to be shared* (Gateway `Programmed`, listener attaching
routes, metallb IP assigned) rather than only that one curl succeeds.

**What a resolution looks like.** Confirm one-host reachability + issuer is the
intended proof for this step (the append-mechanism is proven when Feature 9's
second host lands), or tighten the test with assertions on Gateway `Programmed`
status, the metallb-assigned ingress IP, and listener `AttachedRoutes`, so the step
verifies the shared substrate and not just a single route.

---

## 2026-07-08 — Q6: Is grepping `curl -kv` stderr a robust encoding of "issued by the local CA"? [Implementation surprise] — OPEN

**Question (falsifiable).** The TLS half of the contract is asserted by
`run curl -kv …` followed by `grep -Eqi "issuer:.*Agrippa Local Dev CA"` over the
merged output. curl's `-v` certificate dump is human-readable **diagnostic** text
whose format varies by curl version and TLS backend (macOS system curl has shipped
against Secure Transport, LibreSSL, and OpenSSL at different times; the `issuer:`
line label, and even whether the peer-cert block prints, differ between backends),
and `curl` is **not** among the `mise`-pinned tools — it is operator-provided
system curl. Does grepping verbose stderr durably encode "the leaf was issued by
the local CA," or is it brittle to the operator's curl/TLS backend — able to pass
or fail for reasons unrelated to whether cert-manager wired the Gateway cert?

**Assumption challenged.** That curl `-v` issuer output is a stable interface. It
is an unversioned debug format on an unpinned binary, not a contract surface.

**What a resolution looks like.** Confirm the target environments' curl is
consistent enough that the grep is reliable (and, if so, consider pinning curl), or
re-encode the assertion on a stable interface — e.g.
`openssl s_client -connect 127.0.0.1:443 -servername <host> </dev/null 2>/dev/null |
openssl x509 -noout -issuer` (stable `issuer=CN = Agrippa Local Dev CA`), or inspect
the `agrippa-gateway-tls` Secret's certificate directly via `kubectl` + `openssl`.
Also consider asserting the issuer **chain** validates to the CA (not just that the
CN substring appears), so the check means "signed by our CA," not "presents a cert
that claims our CN."

---

## 2026-07-08 — Q7: Does "the Gateway terminates client TLS" preserve the parity seam, or encode a dev-only cert topology? [Design assumption / Research gap] — OPEN

**Question (falsifiable).** The shared contract has the Istio `Gateway`
**terminate** client-facing TLS on `:443` with a cert-manager leaf from the local
CA, and later features "append your host to the Gateway cert." `ARCHITECTURE.html`
§ S8 (Request Path) shows production terminating **public TLS at the Cloudflare
edge**, with `cloudflared` tunneling to the Gateway and cert-manager providing
"internal + mTLS certs" — i.e., in prod the client-facing public cert is the
**edge's**, not the Gateway's. Does the local "Gateway terminates the client TLS,
hosts append to the Gateway's public leaf" contract mirror the prod request path
(parity — the load-bearing project intent), or does the local Gateway **conflate**
the edge role and the gateway role, so that Feature 9 workloads binding to a
Gateway public cert *locally* encode a topology that does not exist in prod (where
their public TLS lives at Cloudflare and the Gateway carries only internal certs)?

**Assumption challenged.** The Purpose's "seams preserved" claim — that swapping
local CA + `nip.io` for public ACME + Cloudflare is a clean overlay swap. The cert
**material** swap (local CA → ACME) is clean; the cert **topology** (Gateway-
terminates vs edge-terminates client TLS) may not be, and the shared contract that
"every later feature binds to" is defined on the topology.

**What a resolution looks like.** Confirm the Gateway `:443` leaf is understood as
the local **stand-in for the edge** (dev-only; `overlays/prod` drops per-host
Gateway public certs in favor of edge TLS + internal-only Gateway certs), and that
later features' cert bindings are overlay-scoped so they vanish cleanly in prod —
or, if the Gateway is meant to hold certs in **both** environments, reconcile that
with `ARCHITECTURE.html`'s "public TLS terminates at the Cloudflare edge." A
reviewer answers by tracing one workload's cert + HTTPRoute from the intended
`overlays/dev` shape to the intended `overlays/prod` shape and checking the contract
survives the swap unchanged.

---

*7 questions posed, all OPEN at the time of this intent review. This review neither
clears the draft gate nor edits the artifact under review; it supplements the human's
(or the long-loop research-and-decide reviewer's) gate review.*

---

**Resolved 2026-07-08 by the long-loop research-and-decide reviewer.** All seven
questions were decided at the design draft gate alongside this design's own Open
Artifact Decisions; the decisions and rationale are recorded in
`../design.md` § Summary → *Resolved by the long-loop reviewer (2026-07-08)* (entries
Q1–Q7). Summary of dispositions — none escalated, all reversible and in recorded scope:
Q1 keep ArgoCD as the proof but route `argocd-server:443` backend-TLS (drops the
`server.insecure` Feature-2 mutation); Q2 keep the shared cert + `from: All` with a
watch-item to split to per-feature certs if the parallel band contends; Q3 keep the
committed IP literals + build-time re-derivation, with the reproducibility gap recorded
and machine-independent derivation parked; Q4 sanction the `--enable-helm` cross-step
touch (additive, bootstrap-applied, does not regress `gitops.bats`); Q5 confirm the
proof, recommend build-phase substrate assertions (Gateway `Programmed`, metallb IP,
`AttachedRoutes`); Q6 re-encode the issuer check on `openssl x509 -noout -issuer`
(operator curl is live-confirmed LibreSSL, so the `curl -v` grep is backend-brittle);
Q7 confirm the Gateway `:443` local-CA leaf is the `overlays/dev` stand-in for the
Cloudflare edge, with per-host public-cert bindings overlay-scoped. The design draft gate
is cleared (`design.md` marker now `*Reviewed 2026-07-08*`).
