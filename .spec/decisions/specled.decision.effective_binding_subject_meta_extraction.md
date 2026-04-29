---
id: specled.decision.effective_binding_subject_meta_extraction
status: accepted
date: 2026-04-29
affects:
  - specled.realized_by
change_type: clarifies
---

# EffectiveBinding Shall Accept Parsed-Subject Maps Directly

## Context

`SpecLedEx.Realization.EffectiveBinding.for_requirement/2` was documented to
accept either a parsed schema struct (`%SpecLedEx.Schema.Meta{}`,
`%SpecLedEx.Schema.Requirement{}`) or a plain map with a top-level
`:realized_by` / `"realized_by"` key. Internally `extract_binding/1`
implemented exactly that contract: `Map.get(map, :realized_by, Map.get(map,
"realized_by"))`.

The triangle task and other downstream callers do not pass `Meta` structs.
They pass parsed-subject maps — the shape produced by `SpecLedEx.Parser` for
an entire `.spec.md` file:

```elixir
%{
  "file" => "...",
  "title" => "...",
  "meta" => %{"realized_by" => %{...}, ...},
  "requirements" => [...],
  ...
}
```

In that shape `realized_by` lives at `subject["meta"]["realized_by"]`, never at
the top level. `extract_binding/1` therefore returned `%{}` for every subject,
which surfaced in `mix spec.triangle` as `effective_binding: %{}` for every
requirement even when the spec declared a perfectly valid subject-level
binding. The closure walk and coverage triangulation worked because
`spec.triangle.ex` has its own `meta_realized_by/1` helper that knows about
the nesting; only `EffectiveBinding` was unaware.

Two valid framings:

1. **Push the extraction to call sites.** Every caller passes
   `meta(subject)` instead of `subject`. The contract stays narrow but every
   call site duplicates the meta-fishing helper.
2. **Teach `EffectiveBinding` about the parsed-subject shape.** Single
   source of truth for "where does `realized_by` live on this thing"; call
   sites pass whatever they have.

## Decision

Adopt framing 2. `EffectiveBinding.extract_binding/1` shall look in this
order and return the first match:

1. `map[:realized_by]`
2. `map["realized_by"]`
3. `map[:meta][:realized_by]`
4. `map[:meta]["realized_by"]`
5. `map["meta"][:realized_by]`
6. `map["meta"]["realized_by"]`

If a top-level `realized_by` is set, it wins over a nested `meta.realized_by`
on the same map — top-level is the more specific shape, so a caller that
explicitly passes a `Meta` struct or a flat map is treated unchanged. The
nested-`meta` path is a strict fallback for parsed-subject inputs.

## Consequences

- `mix spec.triangle` now reports populated `effective_binding` values
  without changes to its own code.
- The contract widens, not narrows: every previously-supported input shape
  still works identically. Adding a new caller that passes `Meta` /
  `Requirement` / flat map is unaffected.
- `spec.triangle.ex`'s private `meta_realized_by/1` helper remains in place
  for the closure walk — it does additional work beyond binding extraction
  (key normalization for tier filtering downstream). The two helpers are
  not merged in this change to keep the blast radius minimal.
- The new requirement `specled.realized_by.effective_binding_accepts_subject_shape`
  on the `specled.realized_by` subject documents the widened contract and
  the precedence rule. A scenario covers the parsed-subject path with a
  tagged test.
