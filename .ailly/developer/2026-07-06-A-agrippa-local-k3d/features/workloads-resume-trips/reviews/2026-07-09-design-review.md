# Design review, 2026-07-09 (Workloads resume + trips)

Composed review of `design.md` + `tests/workloads.bats` during the Design phase.
Three reviewers dispatched in parallel, each isolated: base four-criterion
reviewer (plus placeholders/contradictions/ambiguity/scope), the intent-review
ability (poses falsifiable questions), and the clean-comments specialist (on the
test's comments). Convergence (verify, dedupe, rank) and the fix pass were run by
the phase runner, separate from the evaluation agents. Findings below, each with
its disposition.

## Verified clean (traced live against the repo/cluster, held up)

- Sync-seam claims: `apps/workloads.yaml` carries only `automated`, no
  `ServerSideApply`/`ServerSideDiff`; `observability`/`core`/`storage`/`platform`
  all carry the pair; `apps/core.yaml` documents argoproj/argo-cd#22151 verbatim.
- Shared cert carries exactly 5 SANs live; neither workload host present yet.
- RED baseline: `workloads` Synced/Healthy on `resources: []`; both dev hosts +
  `/blog` + `/healthz` return 404 live; `bats tests/workloads.bats` fails at the
  first resume `/` 200 assertion, exit 1.
- `tests/agrippa.bats`: last touched `a9cdfbc`, `git diff HEAD` empty (verify-only
  is correct).
- No sibling app namespace (platform/observability/core) carries an
  ambient/injection label; forgejo's namespace is bare -> the design's bare
  `resume`/`trips` namespaces are consistent (intent Q7). **Resolved: no change;
  added a one-line note to § Intra-workload sync-wave scheme.**
- All `decision a`..`k` letters map correctly; requirements 1-9 each map to a
  section; no TODO/TBD placeholders; no scope over-reach.

## Findings and disposition

1. **Em-dashes as punctuation (base #1; HIGH as flagged).** The base reviewer
   compared to repo *code* convention (`--`). Sibling *design docs* use em-dashes
   heavily (forgejo design.md 85, parent design.md 25), so the artifact class
   tolerates them, but the user's global instruction explicitly forbids em-dashes
   as punctuation. **Resolved (fixed): design.md rewritten to remove em-dashes,
   restructured into complete sentences / commas / parentheses.** The `*Draft*`
   emphasis marker and `[n]` IEEE citation references remain (both required
   conventions; the markdownlint warnings on them match every sibling design).

2. **`/blog` directory-index shape asserted not verified (intent Q5).** The
   trailing-slash-redirect failure-mode and the nginx `try_files` shape assume
   `docs/blog/index.html`, inferred from `package.json`/`posts/`, not a built
   site. **Resolved (fixed): § Challenges now flags the alternative flat
   `blog.html` output and makes the exact serving config + failure-mode cause a
   build-verify; the test comment softened to "assumed directory-index shape,
   build-verified".**

3. **alpine/musl vs glibc build risk + resume offline-ness (intent Q6).** Stage 1
   base is musl (`node:24-alpine`) while CI is glibc; biome ships musl-native
   binaries; trips is confirmed offline but resume's post-`npm ci` build is not.
   **Resolved (fixed): § Challenges adds the libc/offline build-verify and
   proposes `node:24` (glibc) unless alpine is confirmed to build both cleanly;
   stage-1 base softened from `node:24-alpine` to `node:24`.**

4. **helm-unittest "catches drift between the two representations" overstates
   (intent Q4).** helm-unittest tests the chart against author expectations, never
   compares to the live overlay. **Resolved (fixed): § The Helm charts corrected
   to the honest "aligned by discipline, not a generator" framing; a `helm
   template`-diff check named as the way to catch drift if the risk grows.**

5. **trips/resume "real content" over-claims vs the test (base #5; intent
   Q1/Q3).** The test proved trips with only `<html`; Closing Bell task 3 wants
   "trip index AND a real trip detail page"; a resume/trips image swap would go
   undetected. **Resolved (partially fixed, partially scoped-to-human-study):**
   (a) added `grep -qi 'trip'` to the trips assertion as a discriminating token
   (parallels resume's `david`); (b) reworded design metrics + Feature Test to
   state the test is a reachability-and-render backstop and that Task 2/3 *depth*
   is judged by the human Closing Bell study, not this one test; (c) test comments
   name a specific trip-detail-page assertion as a build-phase tightening.

6. **"Certificate" dropped vs cleared decision h / parent item 2 (intent Q2).**
   The design mints no per-workload Certificate (shared single-listener Gateway
   references only `agrippa-gateway-tls`). This overrides the literal wording of a
   cleared decision. **Resolved (surfaced for human ratification): added a
   ratification note in § The shared Gateway routes and a dedicated Open Artifact
   Decision entry. POSED — the human confirms at the draft gate that the
   shared-cert SAN append discharges "Certificate".**

7. **Unsurfaced Open Artifact Decisions (intent Q8).** Probe design and
   one-vs-two nginx config were invented but not surfaced; namespace item read as
   "confirm prescribed default." **Resolved (fixed): probe target added as an OAD;
   the nginx one-vs-two question folded into the Dockerfile OAD; namespace OAD
   reframed as confirming the strong per-workload default.**

8. **"empty charts/" -> absent (base #3); decision-N namespace collision (base
   #2).** **Resolved (fixed): "absent until now" wording; a decision-reference
   convention note added to the framing blockquote.**

9. **Conciseness: decision h / imagePullPolicy / bootstrap restated many times
   (base #4).** **Resolved (partially): the full-rewrite trimmed several repeats;
   some deliberate restatement of load-bearing decisions is kept, as is normal for
   a design doc.**

## Clean-comments (tests/workloads.bats) — all resolved (fixed)

- Stale "build phase may tighten this" breadcrumb -> reworded to standing "why
  the token is deliberately loose" intent.
- Header exact-`200` nginx-directive duplication -> header parenthetical trimmed;
  inline THEN 3 owns the directive text.
- Rot-prone `ROUTING.md` pointer at the `/blog` comment -> softened to the stated
  invariant ("apex-path placement").
- Precision slips: "pulling a locally-imported image" -> "running ...
  (imagePullPolicy: Never)"; "empty `platform`" -> "argocd-only `platform`".
- Kept (calibrated to house style): request-path narration, the `set -e` /
  `grep -q` gating rationale, the RED-baseline block, helper docblocks.

## Remaining for the human at the draft gate

- **Finding 6 (POSED):** ratify that no per-workload `Certificate` is authored
  (shared-cert SAN append instead). Surfaced as an Open Artifact Decision.
- The other Open Artifact Decisions (Dockerfile/nginx layout + one-vs-two config,
  image tags, probe targets, chart internals, namespaces) per design.md § Open
  Artifact Decisions.
