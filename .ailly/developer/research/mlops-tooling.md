# Platform LLM Tier: Research Note on Mlflow and "Benchflow"

*Draft 2026-07-06* — researched by a dispatched subagent (opus). Review, then remove this marker line to clear.

_Scope: evaluating two candidate self-hosted services named in Agrippa's original brief for the deferred **Platform LLM** tier (current planned members: Ollama, ZenML, LangFuse). This tier has no consumer until DavidBot gets its own design cycle, so every verdict below is calibrated against "should this be adopted now vs. parked as a researched candidate."_

---

## 1. Mlflow

### What it is
MLflow is the most widely adopted open-source platform for managing the ML/AI lifecycle, self-hostable with no vendor lock-in. It spans four areas:

- **Experiment tracking**: log params, metrics, and artifacts per run; query and compare runs in a UI.
- **Model registry**: a UI and API for model versioning and promotion. Register a model from a run, get auto-versioned entries (v1, v2, ...), attach tags and descriptions, use aliases (e.g. `@champion`), and transition versions across stages (Staging/Production). Each version links back to the run that produced it, giving full lineage and reproducibility.
- **Model packaging and deployment**: package and ship to Docker, Kubernetes, SageMaker, Azure ML, and similar targets.
- **GenAI features (newer)**: LLM/agent tracing, a prompt registry with versioning, and an LLM-as-a-judge evaluation framework that attaches automated scorers (correctness, relevance, safety) directly to traces, with a comparison UI for eval results.

### Redundancy analysis vs. ZenML + LangFuse
The overlap is real but partial, and it splits cleanly:

- **vs. ZenML (orchestration + tracking).** ZenML is a pipeline orchestrator and infrastructure-abstraction layer. It tracks lineage and artifacts at the pipeline level and has a "Model Control Plane." Crucially, ZenML does **not** try to replace MLflow here: it ships a native integration that plugs MLflow in as an experiment-tracker and model-registry stack component, and its own docs recommend doing exactly that. So MLflow's run-level metric logging, experiment-comparison UI, and (especially) its mature standalone model registry and versioning are *additive* to ZenML, not duplicative. This is the strongest distinct-value argument for MLflow.
- **vs. LangFuse (LLM observability).** MLflow's *GenAI* surface (tracing, prompt versioning, LLM-as-judge eval) **overlaps LangFuse substantially**. By MLflow's own comparison page (a vendor source, worth reading with that bias in mind): LangFuse is fundamentally a tracing and prompt-management tool with only rudimentary evaluation, while MLflow claims deeper evaluation (multi-turn, metric versioning, result comparison). Since the tier already commits to LangFuse for tracing and prompt management, MLflow's GenAI half is mostly redundant *for this stack*.

**Net:** MLflow is **not redundant with ZenML**: it contributes a model registry, versioning, and experiment-comparison capability that ZenML's tracking doesn't fully cover, and which ZenML's own docs expect an external tool to provide. It **is largely redundant with LangFuse** on the GenAI/tracing/eval side. The catch: this tier is LLM/agent-centric (Ollama inference plus LangFuse), not classical-ML training. MLflow's high-value half (registry and experiment tracking) only pays off once there is **actual model training or fine-tuning** happening, and DavidBot, as an agent over hosted connectors, may never do that.

### Recommendation: keep as researched candidate (defer)
Do **not** adopt now. Re-evaluate at the start of the Platform LLM cycle, gated on one question: *will DavidBot (or anything on this tier) fine-tune or train models locally?*
- **If yes**: adopt MLflow as the **model registry / experiment tracker**, wired in as a ZenML stack component. Pipeline position: **after ZenML training runs, before Ollama serving**. ZenML trains, logs runs and registers versioned models in MLflow, and a promoted `@champion` version is what gets pulled to the Ollama GPU pool. Let LangFuse keep runtime tracing; don't stand up MLflow's tracing, to avoid duplicating LangFuse.
- **If no** (agent-only, no training): **drop it**. ZenML and LangFuse cover the lifecycle, and MLflow would be idle infrastructure.

---

## 2. "Benchflow"

"Benchflow" is genuinely ambiguous: the name maps to **at least three distinct real projects**. Ranked by likelihood of being what the brief meant (an LLM/agent-era eval tool paired with an ML platform like MLflow):

### Candidate A: `benchflow-ai/benchflow` / benchflow.ai (high confidence, primary)
BenchFlow's self-description is "a frontier environment lab for AI agents," built around the tagline "the universal environment framework." The framing behind that tagline: a benchmark is just a frozen environment.
- **What it does:** runs AI agents against task environments and scores them through one hardened "scored-trajectory" contract. Supports any ACP agent (Claude Code, Gemini CLI, Codex, OpenCode, OpenHands, Pi, or a custom agent); supports single-agent, multi-agent (coder plus reviewer, or simulated user), and multi-round patterns; sandboxes via Docker (local), Daytona (parallel cloud), or Modal (serverless). Ships benchmarks like SkillsBench and ClawsBench, and wraps or lists external ones including SWE-bench (as "SWE-bench Pro" in the framework's own docs), WebArena, and OS-World (the latter two confirmed as benchmark listings on BenchFlow's hosted hub).
- **Outputs / metrics:** per-task `result.json` with rewards, trajectories, and **token usage**; summary reports with **pass rates, costs, and convergence curves**, including **pass@iteration** (capability-vs-cost tradeoff). Also emits ATIF/ADP trajectory records for RL post-training.
- **Maturity:** Apache-2.0 license, active: 280 stars, 1,404 commits, 22 releases, v0.6.4 (June 2026), Python 3.12+ required. Founded by Xiangyi Li around September 2024, per an Inverse profile; the GitHub repo itself was created in January 2025, so the company predates its public code by several months. A hosted platform also exists (benchflow.ai's benchmark hub, previously at a separate `hub.benchflow.ai` subdomain that now redirects into the main site) alongside the OSS framework, so self-hosting means running the OSS repo, not this hosted product. **Unverified:** the specific marketing phrase "LLM evals as an API" could not be confirmed verbatim on current source pages, though a hosted, API-style benchmark hub clearly exists.

### Candidate B: `benchflow/benchflow` (Vincenzo Ferme, USI Lugano; low-to-medium confidence)
An older open-source expert system for automated end-to-end performance testing of distributed systems, driven by a YAML-based DSL, using Docker plus Faban. Focused on Workflow Management Systems / BPMN 2.0 benchmarking. RPL-1.5 license (confirmed in the repo's own LICENSE file), an academic project from the mid-2010s (GitHub repo created September 2015; LICENSE copyright reads 2014-2016). This is the literal "workflow-benchmarking tool" reading of the name, but it is **not LLM-related** and shows no substantive recent development activity. Given the brief pairs "Benchflow" with an ML platform (Mlflow), this is probably *not* the intended reference, but it's a real project named exactly "BenchFlow," so it's worth flagging.

### Candidate C: `Justherozen/FlowBench` (EMNLP 2024; low confidence, name mismatch)
A workflow-guided-planning benchmark for LLM agents. The name is **FlowBench**, not BenchFlow: likely a red herring, listed only so the reversal isn't mistaken later for the target.

### Fit assessment (assuming Candidate A) for a DavidBot-style agent eval pipeline
Strong conceptual fit: Candidate A is purpose-built to run agents against frozen task environments and emit exactly the axes the brief cares about: **quality** (reward / pass rate), **cost** (token usage / dollars), and **capability-vs-cost** (pass@iteration). DavidBot's connectors (Google, Slack, Notion, Linear, GitHub) map naturally onto per-connector task environments, and its **agent-gateway** is the seam BenchFlow would drive.

Caveats for a *personal* deployment:
- It is **RL-environment / coding-agent research infrastructure**: heavier and more ceremony than a one-person eval loop strictly needs. You'd own building DavidBot-specific environments.
- **Latency** is not a first-class metric (it centers reward/pass-rate/cost/tokens). Latency/SLO watching still belongs to the OTel + Grafana SLO tier, and per-call tracing to LangFuse.
- The polished, low-effort path is the **hosted platform**; self-hosting means operating the Apache-2.0 OSS framework with a Docker sandbox on the cluster.

### Recommendation: keep as researched candidate (defer)
Do **not** adopt now: there's no DavidBot to evaluate yet. Park Candidate A for the DavidBot design cycle. When it lands, position it as an **offline evaluation harness that wraps DavidBot's agent-gateway calls**: BenchFlow drives the gateway against a suite of connector task environments, scores trajectories, and feeds quality/cost numbers into LangFuse (as scores/traces) and, if MLflow is adopted, into MLflow (as eval runs). It sits **beside/around DavidBot, not inline in the Ollama→ZenML→LangFuse serving path**: an eval-time consumer, run pre-release and on a schedule, not a request-path dependency.

---

## Summary Table

| Tool | Verdict | One-line reason |
| --- | --- | --- |
| **Mlflow** | **Keep as candidate (defer)** | Adds a real model registry / experiment UI that ZenML expects an external tool to fill, but only pays off if the tier actually trains/fine-tunes models; its GenAI half duplicates LangFuse. |
| **Benchflow** (→ `benchflow-ai/benchflow`) | **Keep as candidate (defer)** | Apache-2.0 agent-eval framework that scores agents on quality/cost/pass@iteration, a strong fit to wrap DavidBot's agent-gateway, but there's no consumer until DavidBot's cycle. |
| _Benchflow (alt: `benchflow/benchflow`)_ | _Drop_ | Aging BPMN/workflow perf-testing expert system, unrelated to LLMs; almost certainly not the intended reference. |

---

## Open Follow-ups
1. **Decide the training question for MLflow.** Confirm whether the Platform LLM cycle will fine-tune/train local models (LoRA/adapters for Ollama) or stay agent-only. This single answer flips MLflow between "adopt as ZenML-backed registry" and "drop."
2. **Confirm the intended "Benchflow."** Verify with the brief's author that `benchflow-ai/benchflow` (not Ferme's BPMN tool or FlowBench) is meant. If self-hosting matters, note that BenchFlow's polished path is the hosted platform; scope the effort of running the OSS framework + Docker sandbox on Agrippa.
3. **Avoid LangFuse/MLflow eval overlap.** If both ever land, draw an explicit line: LangFuse = runtime tracing + prompt management; MLflow = registry + (optionally) offline experiment/eval comparison. Don't run two tracing backends.
4. **Model registry decision even without MLflow.** If MLflow is dropped, decide whether ZenML's own Model Control Plane is sufficient for versioning whatever gets served to Ollama, or whether a lighter registry (e.g. OCI artifacts / a plain object-store convention) suffices. Note: ZenML's Model Control Plane *dashboard* is a ZenML Pro (paid, hosted) feature; the underlying Python API for creating and versioning models ships in the open-source core. Confirm which level of registry UI this tier actually needs before assuming ZenML alone covers it for free.
5. **Latency/cost ownership.** Agent latency SLOs stay in the OTel + Grafana tier per DEVELOPMENT.md; if BenchFlow is adopted, define where its cost/quality reports live (Grafana dashboards vs. LangFuse scores vs. MLflow eval runs) so there's one source of truth.
6. **Revisit at cycle start.** Both verdicts assume today's deferred state; re-run this note when the DavidBot design cycle opens, since BenchFlow (founded ~September 2024, iterating fast toward v0.6.x) and MLflow's GenAI surface are both moving quickly.

**Sources:** [MLflow](https://mlflow.org/) · [MLflow model registry](https://mlflow.org/docs/latest/ml/model-registry/) · [MLflow tracing](https://mlflow.org/docs/latest/genai/tracing/) · [ZenML ↔ MLflow model registry integration](https://docs.zenml.io/stacks/stack-components/model-registries/mlflow) · [ZenML vs MLflow compare](https://www.zenml.io/compare/zenml-vs-mlflow) · [ZenML Model Control Plane (Pro)](https://docs.zenml.io/pro) · [MLflow vs Langfuse](https://mlflow.org/langfuse-alternative/) · [benchflow-ai/benchflow (GitHub)](https://github.com/benchflow-ai/benchflow) · [BenchFlow site](https://www.benchflow.ai/) · [BenchFlow hub](https://hub.benchflow.ai/) · [Inverse profile of BenchFlow/Xiangyi Li](https://www.inverse.com/tech/building-ais-testing-ground-benchflows-mission-as-explained-by-xiangyi-li) · [benchflow/benchflow (BPMN perf-testing)](https://github.com/benchflow/benchflow) · [Justherozen/FlowBench (EMNLP 2024)](https://github.com/Justherozen/FlowBench)
