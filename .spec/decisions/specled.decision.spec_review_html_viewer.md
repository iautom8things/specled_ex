---
id: specled.decision.spec_review_html_viewer
status: accepted
date: 2026-05-03
affects:
  - specled.package
  - specled.mix_tasks
  - specled.spec_review
---

# Spec Review Surface Is A Self-Contained HTML Viewer

## Context

Specled_ex already produces structured triangulation across spec ↔ binding ↔ test ↔ coverage, but that structure is consumed only by the `mix spec.check` pass/fail gate. Reviewers see GitHub's flat, file-first diff view and have no way to read the structure during review. The "no human in the loop" critique against specled_ex (vs. dashboard-first tools like acai) is downstream of that visibility gap — the human IS in the loop on every PR, but they're reviewing the wrong artifact.

Several distribution shapes were considered for a richer review surface:

- a CLI text renderer (cheap, no team review)
- a GitHub-comment markdown summary (limited by markdown's expressiveness)
- a custom GitHub App with a check-run UI (requires hosted infra)
- a standalone web service (richest, biggest investment)
- a self-contained HTML artifact rendered by a mix task (no hosting, no markdown ceiling, no divergence between local and CI)

We also considered making the artifact interactive — embedding per-subject acceptance checkboxes that produce a signed manifest the reviewer commits back. That couples the viewer to an acceptance state model we have not yet designed.

## Decision

`mix spec.review` produces a self-contained HTML file. CSS and JavaScript are inlined; no network resources are fetched at view time. The same code path renders the artifact locally and in CI.

The HTML is a **read-only viewer in v1**. It surfaces the triangle (spec / code / coverage / decisions) so a human reviewer can read it, but it does not record acceptance state, per-subject sign-off, or persistent durability of approvals. Acceptance continues to happen on the host platform's existing flow (e.g., GitHub's Approve button).

CI distribution uses GitHub Pages: a workflow deploys the rendered HTML to `gh-pages` under `/pr/<PR>/index.html` and posts (or updates) a PR comment linking to it. No third-party GitHub App, no hosted backend.

## Consequences

The visibility gap is closed at the cheapest point on the spectrum — a single mix task and a small workflow. The artifact is trivially shippable: as a CI upload, attached to a PR comment, archivable, emailable, openable offline.

Choosing read-only for v1 means we ship the viewer first and design acceptance state once we see how reviewers actually use the surface. If we later add per-subject acceptance, the data model will be informed by usage rather than speculation. The cost is that the "human in the loop" critique is only partially answered today: reviewers can see the triangle, but the act of approving a particular subject's contract is still implicit (one approval covers the whole PR).

GitHub Pages distribution requires the host repo to enable Pages and accept that the rendered artifacts grow in `/pr/<PR>/` paths until a separate cleanup job is added. Auto-cleanup of stale paths is intentionally out of scope for v1.

The workflow uses plain `git` and the `gh` CLI for the deploy and comment steps, with no dependency on third-party Actions beyond `actions/checkout`, `erlef/setup-beam`, and `actions/cache`. This keeps the supply chain minimal.
