# Agent Gateway Architecture for DavidBot (Agrippa)

*Draft 2026-07-06* — researched by a dispatched subagent (opus). Review, then remove this marker line to clear.

Research note, captured 2026-07-06, so the decision survives to the design cycle. DavidBot is not yet designed; this fixes what "agent gateway" should mean before the term drifts.

## Recommendation

"Agent gateway" in Agrippa should be treated as a **pattern spanning two distinct planes, not a single service**. The term is overloaded across the ecosystem, and the two planes have different lifecycles and owners. Plane one is a **model-facing LLM proxy** (recommend **LiteLLM proxy**) that fronts Ollama and any future hosted-model fallback behind one OpenAI-compatible `/v1` endpoint, adding virtual API keys, per-caller rate limits, cost accounting, and a Langfuse callback. Plane two is a **tool-facing MCP gateway** (recommend **IBM ContextForge / `mcp-context-forge`**) that aggregates one self-hosted MCP server per connector (Google, Slack, Notion, Linear, GitHub) behind a single MCP endpoint with centralized discovery, policy, and OTel tracing. Keycloak sits in front of both planes as the OIDC authorization server for *inbound* auth (is this caller allowed to reach the model/tools); the connectors' own OAuth apps and per-service tokens are the *outbound* auth problem, vaulted through the External Secrets Operator backend. LiteLLM complements rather than overlaps Langfuse: LiteLLM does routing/auth/quota/cost and *emits traces into* Langfuse, which owns evaluation and trace storage. For a single-operator start, the MVP collapses plane two to single-user API tokens and an optional thin aggregator, deferring per-user 3-legged OAuth.

## Component List

- **DavidBot (agent runtime)**: the chatbot/research-agent process; depends on Ollama and ZenML; talks OpenAI API to the LLM proxy and MCP to the tool gateway.
- **LiteLLM proxy** (model-facing gateway): one OpenAI-compatible endpoint in front of Ollama plus a future hosted fallback; issues virtual keys, enforces rate/cost limits, routes and falls back across backends. MIT-licensed (an `enterprise/` subdirectory carries a separate license), CPU-bound, self-host-friendly. [BerriAI/litellm](https://docs.litellm.ai/docs/proxy/logging)
- **Ollama** (Platform LLM tier): local inference runtime on the GPU node pool with scale-to-zero; a backend behind LiteLLM, not itself a gateway.
- **Langfuse**: LLM observability/tracing and eval store, fed by LiteLLM's native `langfuse` and `langfuse_otel` success/failure callbacks. [LiteLLM↔Langfuse](https://langfuse.com/integrations/gateways/litellm)
- **IBM ContextForge MCP gateway** (`mcp-context-forge`): tool-facing aggregator/registry/proxy exposing many MCP servers as one endpoint. Virtual servers, REST/gRPC-to-MCP translation, guardrails, OTel tracing, dedicated Keycloak SSO support (auto-discovered via `SSO_KEYCLOAK_*` env vars) plus generic OIDC. Apache-2.0, Python, Docker/K8s, Redis-backed federation, reached 1.0 (v1.0.4) in June 2026. [IBM/mcp-context-forge](https://github.com/IBM/mcp-context-forge)
- **Per-connector MCP servers** (self-hosted pods behind the gateway):
  - **Google (Gmail/Calendar/Drive)**: `taylorwilsdon/google_workspace_mcp` (12-service Workspace coverage including Gmail/Calendar/Drive, native OAuth 2.1, stateless mode, org-central hosting). Alternatives: `j3k0/mcp-google-workspace` (Gmail and Calendar only), `ngs/google-mcp-server`. [taylorwilsdon/google_workspace_mcp](https://github.com/taylorwilsdon/google_workspace_mcp)
  - **Slack**: the original reference server in `modelcontextprotocol/servers` is archived; its lineage continues as `zencoderai/slack-mcp-server` (bot token via `SLACK_BOT_TOKEN`). Community alternatives: `korotovsky/slack-mcp-server` (a Slack app bot/user OAuth token, or a stealth mode on browser session tokens) and `jtalk22/slack-mcp-server` (browser session tokens only, no Slack app install, ships a paid hosted tier). The last one is a different trust model from the self-hosted, service-account pattern used for the other connectors here and needs a closer look before it's picked. [servers](https://github.com/modelcontextprotocol/servers)
  - **Notion**: official `makenotion/notion-mcp-server`, self-hostable over Streamable HTTP (default port 3000) with an internal-integration token. [makenotion/notion-mcp-server](https://github.com/makenotion/notion-mcp-server)
  - **Linear**: the official server is remote/managed only, OAuth via `mcp.linear.app`. Both self-host alternatives considered for this note turned out stale on verification: `scoutos/mcp-linear` no longer resolves on GitHub (unverified whether renamed, made private, or removed), and `jerhadf/linear-mcp-server`'s own README marks it deprecated in favor of the official remote server. `tacticlaunch/mcp-linear` turned up as active in this pass but is unvetted. Re-survey before committing; see Open Follow-ups. [Linear MCP](https://linear.app/docs/mcp)
  - **GitHub**: official `github/github-mcp-server`, self-hostable via `ghcr.io/github/github-mcp-server` with a PAT (also has a hosted remote variant). [github/github-mcp-server](https://github.com/github/github-mcp-server)
- **Keycloak** (already planned): in-cluster OIDC authorization server for *inbound* auth to both gateways; OAuth 2.1 with PKCE, dynamic client registration, token introspection, RFC 8414 metadata. (OAuth 2.1 is still an IETF draft, not a ratified RFC, but it is the de facto target for MCP authorization.) [MCP authorization](https://modelcontextprotocol.io/docs/tutorials/security/authorization)
- **External Secrets Operator + backend** (pending separate research): stores connector OAuth *client* credentials and long-lived *refresh* tokens in the external backend, syncs to K8s Secrets, and drives rotation via `refreshInterval`. [ESO rotation](https://external-secrets.io/main/api/spec/)

## Connector/Credential Flow

There are **two OAuth layers**; conflating them is the main design trap.

**Layer 1: Inbound (caller → gateway), owned by Keycloak.** DavidBot authenticates to the LLM proxy and the MCP gateway with a short-lived, scoped token issued by Keycloak. The MCP spec cleanly separates the *token issuer* (Keycloak) from the *resource server* (the MCP gateway): Keycloak mints JWT access tokens; the gateway validates signature and `iss`/`exp`/scope locally against Keycloak's public keys. ContextForge has dedicated Keycloak SSO support and MetaMCP lists Keycloak as an explicitly tested OIDC provider; both also accept generic OIDC. This layer answers "may this agent call these tools/models," and never carries a Google/Slack credential.

**Layer 2: Outbound (MCP server → SaaS), owned by the connector and secrets backend.** Each of Google, Slack, Notion, Linear, GitHub has its *own* OAuth app (client id/secret) and its own per-user access/refresh tokens. Best practice is a **token-vault / token-broker** pattern: the gateway or connector holds the SaaS tokens; the agent never receives them. Concretely, with Agrippa's planned pieces:

- **Client credentials** (the OAuth app id/secret per connector) live in the ESO backend and sync into each connector pod as a K8s Secret. These are static and rotate rarely: a clean ESO fit.
- **User tokens**: for a 3-legged OAuth (auth-code) flow, the connector (e.g. `google_workspace_mcp`, which supports an external auth server) runs the consent redirect once, then holds access and refresh tokens. Long-lived **refresh tokens** are persisted to the ESO backend (Vault/cloud SM) so they survive pod restarts; ESO's `refreshInterval` re-syncs them. Short-lived **access tokens** are refreshed in-process by the connector at roughly 80% of TTL. That refresh cadence is faster than ESO's one-directional sync should own, so keep access-token refresh inside the connector/gateway, not in ESO.
- **Keycloak identity brokering** can optionally hold the Google/GitHub/Slack IdP links so a single Keycloak login federates the SaaS consent, but for a machine agent the simpler path is per-connector OAuth apps with tokens vaulted as above.

Prose diagram:

```
DavidBot
  ├─(OIDC token from Keycloak)→ LiteLLM proxy ──→ Ollama (GPU, scale-to-zero)
  │                                   └────────→ hosted-model fallback
  │                                   └──(callback)→ Langfuse (traces/eval)
  │
  └─(OIDC token from Keycloak)→ ContextForge MCP gateway
                                     ├─→ Google MCP  ──(OAuth app + refresh token, vaulted)→ Gmail/Cal/Drive
                                     ├─→ Slack MCP   ──(bot/user token, vaulted)──────────→ Slack
                                     ├─→ Notion MCP  ──(integration token, vaulted)───────→ Notion
                                     ├─→ Linear MCP  ──(API key, vaulted)────────────────→ Linear
                                     └─→ GitHub MCP  ──(PAT/OAuth, vaulted)──────────────→ GitHub

Credential store:  ESO backend (Vault/cloud SM) → K8s Secrets → connector pods
                    (client secrets + refresh tokens; access tokens refreshed in-connector)
```

**MVP vs fuller:**
- **MVP (single operator):** DavidBot → **LiteLLM** → Ollama, traces to Langfuse. Connectors run as pods using **single-user tokens** (GitHub PAT, Linear API key, Notion internal-integration token, Slack bot token, Google single OAuth refresh token or service account), stored as K8s Secrets via ESO. Skip 3LO/per-user OAuth and the token vault. Optionally front the connectors with a **thin aggregator** (MetaMCP or MCPJungle) so DavidBot sees one MCP endpoint; if DavidBot is the only consumer, even that is deferrable. Keycloak guards the DavidBot UI.
- **Fuller:** **ContextForge** MCP gateway with Keycloak OIDC inbound, per-connector **3-legged OAuth with a token vault**, ESO-backed refresh-token rotation, policy/guardrails, and OTel traces into the platform's Alloy/Mimir/Grafana stack alongside Langfuse.

## Alternatives Considered

- **LLM proxy: Portkey vs Kong AI Gateway vs LiteLLM.** Portkey's OSS gateway includes guardrails, routing/fallbacks, and multi-modal support, but access control/key management, semantic caching, and prompt management all sit in its hosted/enterprise tier, not the open-source repo. Kong's own benchmark (proxy-only configuration, no auth/caching policies enabled) reports over 200% higher throughput than Portkey and over 800% than LiteLLM, with 65% and 86% lower latency respectively, vendor-run and not independently verified. Kong AI Gateway is the right call *if you already run Kong*, but it pulls in Kong's whole control plane. For a personal K8s platform with no existing Kong, **LiteLLM** wins on self-host friendliness, MIT license, 100+ providers, and a native Langfuse callback. [gateway comparison](https://konghq.com/blog/engineering/ai-gateway-benchmark-kong-ai-gateway-portkey-litellm)
- **MCP gateway: MetaMCP / MCPJungle / Docker MCP Gateway / mcpproxy vs ContextForge.** MetaMCP has the best OIDC story (Keycloak tested) and clean namespace→endpoint aggregation, but it does not manage per-connector downstream OAuth; it only supports static credential injection via `${ENV_VAR}` references. MCPJungle and Docker MCP Gateway are simpler registries. **ContextForge** is the most complete for a Kubernetes platform (federation, guardrails, REST/gRPC-to-MCP, OTel, Apache-2.0, reached 1.0 in June 2026). MetaMCP is the strong MVP-tier pick if you want OIDC now with less surface. [awesome-mcp-gateways](https://github.com/e2b-dev/awesome-mcp-gateways)
- **"One gateway service" framing.** Rejected: no single self-hostable product cleanly does both LLM-proxy and MCP-tool-aggregation *and* per-connector credential vaulting today. Forcing it into one box couples the model plane's cost/rate concerns to the tool plane's OAuth lifecycle.
- **Managed remote MCP servers** (Linear's hosted server, GitHub's remote server, Google-managed MCP). Lower effort but off-platform and outside Agrippa's self-hosting posture; acceptable as a fallback per connector, not the default.
- **Keycloak identity brokering for SaaS consent** instead of per-connector OAuth apps. Elegant for human SSO but overkill for a single machine agent; per-connector apps plus vaulted tokens are simpler and more explicit.

## Open Follow-ups

1. **Secrets backend dependency.** This design assumes the pending ESO backend research lands on something that stores refresh tokens (Vault or a cloud SM). Confirm the backend supports frequent-enough `refreshInterval` and Kubernetes-auth (no static ESO token). The access-token-refresh split (in-connector vs ESO) needs validating against the chosen connectors.
2. **Do we even need the MCP gateway at MVP?** If DavidBot is the sole MCP consumer, a gateway is optional. Decide the trigger: add ContextForge/MetaMCP when a second agent or multi-user access appears.
3. **Linear self-host connector is stale.** Both self-host options considered here, `scoutos/mcp-linear` and `jerhadf/linear-mcp-server`, no longer look viable (repo unreachable and explicitly deprecated respectively). Re-survey self-hosted Linear MCP servers before implementation, or default to Linear's managed remote server for this one connector.
4. **Per-user vs single-user tokens.** Personal project implies single-user; confirm no scenario needs 3LO consent (e.g. acting as other Google/Slack identities) before committing to the simpler token model.
5. **Keycloak ↔ MCP OAuth 2.1 conformance.** Verify the chosen connectors/gateway accept Keycloak-issued JWTs (dynamic client registration, RFC 8414 metadata, PKCE) end-to-end; some MCP servers assume their own embedded auth.
6. **Observability overlap.** Decide the trace boundary: LiteLLM→Langfuse for LLM calls, ContextForge→OTel→Grafana for tool calls. Confirm whether Langfuse should also receive MCP tool-call spans or stay LLM-only.
7. **ZenML's role.** Clarify whether ZenML pipelines call the LLM proxy (and thus need their own Keycloak client and LiteLLM key) or sit entirely outside the gateway pattern.
8. **Guardrails/policy ownership.** LiteLLM lacks built-in content guardrails; decide whether policy lives in ContextForge plugins, a Portkey sidecar, or is deferred.

Sources: [litellm proxy](https://docs.litellm.ai/docs/proxy/logging) · [litellm↔langfuse](https://langfuse.com/integrations/gateways/litellm) · [Kong AI gateway benchmark](https://konghq.com/blog/engineering/ai-gateway-benchmark-kong-ai-gateway-portkey-litellm) · [IBM ContextForge](https://github.com/IBM/mcp-context-forge) · [MetaMCP](https://github.com/metatool-ai/metamcp) · [MCPJungle](https://github.com/mcpjungle/MCPJungle) · [awesome-mcp-gateways](https://github.com/e2b-dev/awesome-mcp-gateways) · [google_workspace_mcp](https://github.com/taylorwilsdon/google_workspace_mcp) · [notion-mcp-server](https://github.com/makenotion/notion-mcp-server) · [github-mcp-server](https://github.com/github/github-mcp-server) · [Linear MCP](https://linear.app/docs/mcp) · [MCP authorization](https://modelcontextprotocol.io/docs/tutorials/security/authorization) · [MCP token brokering](https://obot.ai/blog/mcp-token-security-token-brokering/) · [OAuth for MCP token mgmt](https://www.truefoundry.com/blog/oauth-mcp-enterprise-token-management) · [ESO rotation](https://external-secrets.io/main/api/spec/)
