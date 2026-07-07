# Agrippa Routing Policy: Domain vs Path

## Summary / Recommendation

**Rule of thumb: default every new app to a *path* under an existing hostname. Promote it to its own *subdomain* only when a concrete "promotion trigger" fires, and to its own *apex domain* only for standalone product identity.**

A path is the cheapest placement: one route rule, zero new certs, zero new DNS records, one clause on an existing edge-auth app. A subdomain costs a DNS record, a Gateway listener + HTTPRoute host, usually a new edge-auth app, and sometimes a new cert. At single-operator scale each cost is small but they compound, so make the platform *pay* for a subdomain by requiring a reason.

The four promotion triggers, any one of which justifies a subdomain:

1. **Deploy isolation**: an app's GitOps origin repo or secrets need broader trust than a shared host's source repo carries. A path *cannot* buy this; it inherits a host site's deploy pipeline.
2. **Edge-session isolation**: gating at the edge (Cloudflare Access) calls for a clean per-app session boundary. The `CF_Authorization` cookie is scoped per hostname, so a subdomain gets session isolation for free. A path shares a host's cookie scope unless you opt into per-path cookies.
3. **Whole-environment overlay**: the thing is a parallel copy of an entire platform (staging), where a subdomain is the natural environment boundary.
4. **Product identity**: a distinct product or brand that should stand on its own. This one escalates to a *separate apex domain*, not merely a subdomain.

## Decision Framework

### 1. Cloudflare Access policy scope: path vs hostname

Cloudflare Access gates paths cleanly. A self-hosted Access application can protect a specific path (`davidsouther.com/agathon`) while the rest of the hostname stays public, with predictable precedence: a more specific path rule wins over a broader one, and a child path *inherits* its parent's policy unless overridden. Path wildcards are allowed, at most one per slash-segment. Limitations to know: **path definitions cannot use port numbers, query strings, or anchors**; Access strips any of these if present.

The meaningful difference is **session-cookie scoping**. The `CF_Authorization` cookie is, by default, scoped to domain and subdomain, not to path. Consequences:

- **Subdomain gating gives session isolation for free.** `trips.davidsouther.com`'s cookie cannot be presented to the public apex, and vice-versa.
- **Path gating shares the host cookie by default.** Every Access-gated path on `davidsouther.com` sees the same cookie. Each Access app still validates its own policy and its own JWT `AUD`, so paths remain *logically* isolated at the policy layer, though the cookie surface spans the whole hostname. To force true per-path session isolation you must enable the **Cookie Path Attribute**, after which a user authenticated to `/path1` must re-auth for `/path2`. That is an opt-in, fiddlier, and weaker story than a subdomain's default.
- **Multi-hostname apps:** one Access app can span multiple hostnames and issue a shared JWT across them, confirmed by Cloudflare's own Access blog. Community reports consistently put the practical cap at 5 hostnames per app; that exact number is not stated in Cloudflare's primary docs, so treat it as unverified. Useful, but orthogonal to the path/subdomain choice.

**Finding:** per-path Access works and is well-supported, but per-subdomain gating has strictly cleaner default session isolation. If an app is edge-gated *and* needs its session walled off, prefer a subdomain.

### 2. TLS / cert-management (cert-manager + Cloudflare)

Because the platform validates via **DNS-01** on Cloudflare, wildcards are cheap to obtain. Wildcards also *require* DNS-01: Let's Encrypt's HTTP-01 challenge cannot issue wildcard certificates at all (the same is true of TLS-ALPN-01). Coverage rules that drive the decision:

- A wildcard `*.davidsouther.com` covers **exactly one label**: `trips.`, `staging.`, `agathon-if-it-were-a-subdomain.`, but not the apex `davidsouther.com` and not a nested subdomain like `foo.staging.davidsouther.com` (two labels deep). Apex and wildcard live on one cert as two SANs.
- **Adding a path = zero cert work.** Same hostname, same existing cert.
- **Adding a subdomain under an existing wildcard = zero cert work** (covered by the wildcard SAN).
- **Adding a subdomain not covered by a wildcard** (a nested `*.staging`, or a brand-new apex like `ailly.dev`) = a new SAN or an entirely new certificate + issuer flow.

**Finding:** with a `*.davidsouther.com` wildcard in place, single-label subdomains carry *no* extra cert burden, so cert cost is only a real argument against **new apex domains** and **nested-deeper subdomains**, not against ordinary subdomains.

### 3. Istio Gateway API HTTPRoute matching

The hostname is the initial filter; within a matched host, **path specificity decides** (exact > longest prefix > method/header/query). Across multiple HTTPRoutes on one gateway, ties break by oldest route, then `namespace/name` alphabetical. These precedence and tie-break rules are defined in the Gateway API specification itself, not in Istio's own docs, which explicitly defer to the spec for this detail.

- **Host-based routing** is easier to reason about: each subdomain is its own HTTPRoute, independently owned. A bad edit breaks only that host, keeping blast radius small. Adding a host is a self-contained new object.
- **Path-based routing on a shared host** makes routes *interact* through precedence. A bad or overlapping path rule can shadow a sibling path. Two GitHub issues against Istio's Gateway API support illustrate how confusing nested `PathPrefix` matching gets in practice: istio/istio #47761 reported a `PathPrefix` route matching nothing except `/`, and #52714 reported a nested `PathPrefix` rule swallowing a more specific sibling route. Neither is confirmed as an Istio bug: #47761 was closed after a maintainer could not reproduce it on 1.20, and #52714 was closed as working-as-specified (the Gateway API's `PathPrefix` type matches whole slash-delimited path segments, not substrings, so `/myapp/api/items` is not a prefix of `/myapp/api/items:publish`). Both are still useful evidence that shared-host path matching is easy to misconfigure and hard to reason about, even where the underlying behavior is correct. Blast radius of a bad path route is the whole shared hostname.
- Gateway API does let multiple HTTPRoutes, even cross-namespace, attach to one Gateway listener/hostname (confirmed in the Gateway API multi-namespace guide), so path apps can still have separate route objects and RBAC, though they contend on the same host.

**Finding:** host-based routes are operationally simpler and lower-blast-radius; path-based routes are fine for low-risk, same-trust content but concentrate risk on the shared host.

### 4. Deploy / security isolation

This is the decisive, non-negotiable trigger. **A path is deployed by whatever pipeline owns its hostname.** On Agrippa, `davidsouther.com` is served from a *public* repo, so any path under it is authored and deployed from that public repo's app-of-apps. If an app needs secrets or permissions the public repo should not carry, **a path cannot give you isolation. Only a distinct GitOps boundary (a subdomain with its own repo/app) can.** This is exactly why Trips moved. Deploy-isolation need ⇒ subdomain, full stop; no amount of edge-auth cleverness substitutes.

### 5. Product identity / branding

Independent of security, a thing that is *its own product* deserves its own **apex domain**, not just a subdomain. The test: would a stranger reasonably see this as a separate product with its own name, rather than a feature of the personal site? If yes, own domain (`ailly.dev`). If it's a facet of "David's stuff," a path or subdomain of `davidsouther.com` is honest. Branding alone justifies the *domain* tier even when isolation and cert costs argue against it: you pay deliberately for identity.

### 6. Operational simplicity for a single operator

Tally per placement, at small scale:

| Placement | DNS records | Certs | Routes | Edge-auth apps |
| --- | --- | --- | --- | --- |
| New path | 0 | 0 | +1 rule | +1 path clause (reuse app) |
| New subdomain (under wildcard) | +1 (ExternalDNS, automatic) | 0 | +1 host HTTPRoute + listener | +1 app |
| New apex domain | +1 zone | +1 cert/issuer | +1 host HTTPRoute + listener | +1 app |

ExternalDNS makes the DNS record free in effort, and a wildcard makes the cert free for single-label subdomains, so the real recurring cost of a subdomain is **one more Gateway listener/HTTPRoute and one more Access app to keep in your head**. That is the tax a promotion trigger must be worth paying.

## Applied to Current Apps

| App | Placement | Justified? | Framework-based reason |
| --- | --- | --- | --- |
| `davidsouther.com` + `/blog` | Path (apex root) | Yes | Same public repo, same (no) auth, same identity as the site. No promotion trigger fires; blog is literally the same source and trust as root. Zero cost. |
| `davidsouther.com/agathon` | Path | Yes, conditionally | Gated by *in-cluster* Keycloak OIDC, not edge Access, so the host-cookie nuance (§1) doesn't bite. No deploy-isolation, identity, or environment trigger fires, provided it ships from the same public repo with no secrets that repo shouldn't hold. **Watch condition:** apply the same test that moved Trips; if agathon grows secrets/permissions, promote it to a subdomain. |
| `ailly.dev` | Separate apex domain | Yes | The product-identity criterion (§5) is the driver: a distinct product (cloud SWE agent), not a facet of the personal site. Own cert, route, and auth boundary come along as bonuses. Cert and DNS-zone cost accepted deliberately for brand. |
| `trips.davidsouther.com` | Subdomain | Yes, strongly | The deploy-isolation trigger is decisive and *cannot* be satisfied by a path: the public `davidsouther.com` repo must not carry Trips' broader secrets. The edge-session-isolation trigger reinforces it: because Trips is *edge*-gated by Cloudflare Access, the subdomain gives host-scoped cookie isolation for free (§1) instead of the opt-in per-path cookie workaround. Covered by `*.davidsouther.com`, so no new cert. Double-justified. |
| `staging.davidsouther.com` | Subdomain | Yes | The whole-environment-overlay trigger applies: staging is a parallel copy of the entire platform, so a subdomain is the natural environment boundary. A `/staging` path would entangle staging's routing, blast radius, and cookie scope with prod on the same host. Wrong shape for an environment boundary. |
| `davidsouther.com/davidbot` (future) | **Planned as a path; reconsider as a subdomain** | Not as a path, most likely | Apply the framework rather than the "hypothetically a path" default. A research-*agent* chatbot will almost certainly need model/API/tool secrets exceeding the public repo's trust, so the deploy-isolation trigger fires: subdomain (`davidbot.davidsouther.com`). If it is *also* edge-gated, the edge-session-isolation trigger additionally argues against co-locating it as an Access-gated path sharing the `davidsouther.com` cookie scope. A path is defensible **only** if davidbot ships from the same public repo, holds no privileged secrets, and uses in-cluster OIDC like agathon. That combination is unlikely for an agent with tool access. Plan for a subdomain. |

## Open Follow-ups

- **Nested staging subdomains break the wildcard.** `staging.davidsouther.com` is covered by `*.davidsouther.com`, but if staging mirrors prod's subdomains (e.g. `trips.staging.davidsouther.com`), those are two labels deep and are **not** covered. They need an additional `*.staging.davidsouther.com` wildcard SAN, obtained the same way via DNS-01 on Cloudflare. Decide whether staging replicates subdomains before this bites. Unresolved: does the staging overlay reproduce Trips as a nested subdomain, or fold it into the staging host?
- **agathon's actual repo/secret profile is unverified.** The path recommendation rests on the assumption it ships from the public repo with no privileged secrets. Confirm its GitOps source before treating the path as settled.
- **Edge-auth vs in-cluster-auth boundary is currently mixed** (Trips = Cloudflare Access Tier-1; agathon/ailly = Keycloak Tier-2). The cookie-scoping analysis (§1) only applies to the edge-gated apps. Worth recording a separate rule for *which tier* gates a given app, since that choice interacts with the path/subdomain decision: edge-gated apps lean harder toward subdomains for cookie isolation.
- **davidbot is unbuilt**, so its secret and identity profile is assumed, not known. Re-run the deploy-isolation and product-identity criteria against the real design before committing its placement.
- **The 5-hostname cap on multi-domain Access apps is unverified** against Cloudflare's primary documentation; it is corroborated only by community reports and the Access blog's description of shared JWT issuance, not by an explicit stated limit in the docs checked here.

### Sources

- Cloudflare Access — [Application paths](https://developers.cloudflare.com/cloudflare-one/access-controls/policies/app-paths/) (path precedence, inheritance, wildcards, unsupported URL elements); [Authorization cookie](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/) (cookie scope, Cookie Path Attribute); [Wildcard and multi-hostname support (blog)](https://blog.cloudflare.com/access-wildcard-and-multi-hostname/) (shared JWT across an app's hostnames; exact hostname cap not stated here, see Open Follow-ups)
- cert-manager — [DNS01 / Cloudflare](https://cert-manager.io/docs/configuration/acme/dns01/cloudflare/) (mechanics of the platform's Cloudflare DNS-01 integration; does not itself state the wildcard/DNS-01 requirement); Let's Encrypt — [Challenge types](https://letsencrypt.org/docs/challenge-types/) (wildcard certificates require DNS-01; HTTP-01 and TLS-ALPN-01 cannot issue them)
- Istio — [Kubernetes Gateway API](https://istio.io/latest/docs/tasks/traffic-management/ingress/gateway-api/) (Istio's Gateway API support; explicitly defers precedence details to the spec); Gateway API — [HTTPRoute spec: precedence and tie-breaking rules](https://gateway-api.sigs.k8s.io/reference/api-spec/main/spec/#httprouterule), [multi-namespace HTTPRoute attachment guide](https://gateway-api.sigs.k8s.io/guides/multiple-ns/); nested-`PathPrefix` edge cases (both closed without a confirmed Istio bug — see §3 finding): [istio/istio #47761](https://github.com/istio/istio/issues/47761), [#52714](https://github.com/istio/istio/issues/52714)
