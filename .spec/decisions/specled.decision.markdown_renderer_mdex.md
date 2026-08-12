---
id: specled.decision.markdown_renderer_mdex
status: accepted
date: 2026-08-12
change_type: clarifies
affects:
  - specled.package
  - specled.spec_review
---

# ADR Prose Renders Through MDEx; The Package Accepts One Precompiled-NIF Dependency

## Context

The HTML review artifact renders authored ADR prose to HTML at one call site
(`SpecLedEx.Review.Html.render_markdown/1`, reached from the Decisions tab and
the ADR body diff). That call site used Earmark.

Earmark is marked RETIRED on Hex with reason `deprecated`, and its retirement
notice names MDEx as the replacement. `mix hex.audit` exits non-zero when any
package in the dependency tree is retired, and it takes no flags — there is no
ignore list, no allowlist, and no per-package waiver. Every adopter whose
verification pipeline includes `mix hex.audit` therefore goes permanently red
by depending on specled_ex, and cannot make it green from their own repo. The
first downstream report is exoterm (tracked there as `exoterm-7xj`), whose
`mix preflight` alias passes every other gate — compile with warnings as
errors, format, credo, sobelow, dialyzer, 723 tests — and fails only at
`hex.audit`.

There is no version of Earmark that is not retired: the retirement covers the
package, not a release range.

## Decision

**MDEx replaces Earmark at the single markdown call site.** Options are
declared once as `@markdown_options`:

- `extension: [strikethrough: true, table: true, autolink: true, tasklist: true]`
  and `parse: [smart: true]` — these are opt-in in MDEx and were on by default
  in Earmark. Naming them holds the rendering surface steady rather than
  silently narrowing it, and each is named in
  `specled.spec_review.adr_prose_markdown_surface` with its own assertion, so
  the pinning fails a test if it is undone rather than being decorative.
- `render: [escape: true, unsafe: false]` — ADR prose is authored content, so
  raw HTML renders as visible text rather than live markup, and dangerous link
  schemes are blocked. This is the same safety posture Earmark's
  `escape: true` provided, tightened by `unsafe: false`.
- `syntax_highlight: nil` — MDEx currently defaults it to nil, but a dep bump
  that flipped it would rewrite every fenced block into styled spans. Pinned
  for the same reason the options above are: this surface's output should not
  move when an upstream default does.
- The dependency is pinned `~> 0.13.0`, not `~> 0.13`. An unknown or renamed
  option raises out of `MDEx.parse_document/2` rather than returning an error,
  and MDEx is pre-1.0 with a rename already behind it, so a minor bump is a
  real way to take `mix spec.review` down.
- MDEx's wikilinks extension stays OFF. `[[id]]` refs must survive as literal
  text so `resolve_wikilinks/1` can rewrite them against what actually
  rendered on the page.
- HTML comments in ADR prose are dropped as **document nodes**, before
  rendering. Authoring markers (`<!-- spec-lint:allow-code=... -->`) are
  editorial, not content, and Earmark already hid most of them. Removing them
  from the rendered output instead would be unsafe: `escape: true` escapes link
  and image `title` attributes too, so an authored `[x](url "<!--")` puts a
  comment opener inside an attribute value, where a byte-level strip pairs it
  with the next `--&gt;` and deletes the markup between — hiding prose from the
  artifact and rebinding link text to another href. Dropping
  `%MDEx.HtmlInline{}` / `%MDEx.HtmlBlock{}` comment nodes cannot reach inside
  an attribute, and it leaves `%MDEx.Code{}` / `%MDEx.CodeBlock{}` literals
  alone by construction — so a marker shown inside a code span stays visible
  without any code-region bookkeeping. Other raw HTML is left in place and
  still renders as visible text.

**The package accepts a precompiled-NIF dependency.** MDEx pulls `mdex_native`
through `rustler_precompiled`. specled_ex was previously pure Elixir and BEAM
bytecode; it no longer is. Builds resolve a precompiled artifact for the host
triple from the `mdex_native` GitHub release, falling back to a local Rust
toolchain build when forced. This is the cost of the only maintained
replacement the retirement notice points at, and it is accepted rather than
worked around: the alternative — keeping a retired dependency — imposes an
unfixable red gate on every adopter, which is strictly worse than a build-time
artifact fetch on an unsupported target.

## Consequences

- **Positive:** `mix hex.audit` exits 0 in this repo, and specled_ex's
  dependency subtree stops failing it in adopters, with no adopter-side
  workaround. An adopter can still be red on a retired package of its own.
- **Positive:** MDEx is CommonMark-conformant where Earmark was not. Rendering
  this repo's own `.spec/decisions/` corpus through both renderers at the
  production entry point — ADR bodies with YAML frontmatter stripped, the way
  `SpecLedEx.Review.read_adr_body/2` produces them, so every item below is
  something a reader could actually have seen — turned up four silent
  corruptions of shipped prose, each of which MDEx renders correctly:
  - `specled.decision.doc_identifier_lint_spec_corpus.md` — Earmark parsed a
    trailing `<!-- spec-lint:... -->` marker as a raw-HTML block and swallowed
    the prose around it, so the rendered body simply lost the words
    "`.spec/**` workspace, which the lint never read". Content deletion, not
    reformatting.
  - `specled.decision.cross_vm_temp_names.md` — the code span
    `` `specled_attr_*.jsonl` `` was destroyed into
    `` `specled_attr</em><em>.jsonl` ``, which also broke the following
    `*completed*` into `</em>completed*`.
  - `specled.decision.append_only_finding_budget.md` — `branch_guard` (line 22)
    paired its underscore with `specled_-fm4`'s two lines below, rendering
    `branch<em>guard` and `specled</em>-fm4`.
  - `specled.decision.file_touch_yields_to_realization.md` — an authoring
    marker escaped into reader-visible text with its `--` mangled to an en
    dash (`&lt;!– ... –&gt;`).
  The common causes are intraword underscores and `*` read as emphasis, and
  raw-HTML block handling. Backticks are not reliable protection: the
  `specled_attr_*.jsonl` case above was already a code span and Earmark
  destroyed it anyway.
- **Positive:** ADR fenced code blocks now carry `class="language-<lang>"`
  rather than Earmark's `class="<lang>"`, so the artifact's bundled Prism pass
  highlights them. Previously only diff panes were highlighted.
- **Negative:** adopters building on a platform with no published
  `mdex_native` artifact, or in an environment that cannot reach GitHub
  release assets, need a Rust toolchain and
  `config :rustler_precompiled, :force_build, mdex_native: true`. Air-gapped
  CI that vendors Hex packages but not release assets must vendor the NIF
  artifact too.
- **Negative:** MDEx honors GFM single-tilde strikethrough (`~word~` becomes
  `<del>word</del>`) where Earmark required `~~word~~`. Flanking rules spare
  the approximation idiom this repo actually uses (`~210 decision files in ~8`),
  but an adopter's ADR could be affected.
- MDEx returns no partial render on failure, where Earmark returned HTML
  alongside its error tuple. A render error degrades to the escaped source in a
  `<pre>`, so an ADR body is never silently blank. An invalid option set is
  deliberately NOT degraded — it raises out of `MDEx.parse_document/2`, and
  with the options unvalidated the escaping posture is unknown, so failing the
  task beats rendering authored prose under a posture nobody has verified.
