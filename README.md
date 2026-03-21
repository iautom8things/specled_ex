# SpecLedEx

Local helper package for Spec Led Development repositories.

It provides canonical `mix spec.*` tasks:

- `mix spec.init`
  - scaffolds `.spec/` with starter files, including `README.md`, `AGENTS.md`, and `decisions/README.md`
  - in interactive runs, can also scaffold a local Skill for Spec Led Development
  - keeps `.spec` declarative and current-state only
- `mix spec.plan`
  - reads `.spec/specs/*.spec.md` and `.spec/decisions/*.md`
  - updates `.spec/state.json` with subject and ADR index data
- `mix spec.assist`
  - reads the current Git change set and points at the next subject, proof, or ADR update to make
  - stays read-only in this release
  - supports `--bugfix` for regression-first guidance
- `mix spec.verify`
  - validates authored specs, updates `.spec/state.json`, and exits non-zero when the verification report fails
  - keeps `kind: command` verification execution off by default for fast local runs
- `mix spec.check`
  - runs `plan` plus strict `verify`
  - enables `kind: command` execution by default; use `--no-run-commands` to opt out
- `mix spec.adr.new`
  - scaffolds a durable ADR under `.spec/decisions/`
- `mix spec.report`
  - summarizes source, guide, and test coverage, verification strength, weak spots, and ADR usage
- `mix spec.diffcheck`
  - inspects the current Git diff and fails when code, docs, or tests moved ahead of current-truth subject or ADR updates

## Default Local Loop

<!-- covers: specled.package.default_local_loop -->

Use one small loop by default:

1. make the code, test, or docs change
2. add or tighten the smallest test when behavior changed
3. run `mix spec.assist`
4. if it says `needs subject updates`, update the named subject
5. if it says `needs decision update`, add or revise an ADR only when the change is durable and cross-cutting
6. when it says `ready for check`, run `mix spec.check`

For bug fixes:

```bash
mix spec.assist --bugfix
```

## Local Usage

Add as a path dependency in another project:

```elixir
{:spec_led_ex, path: "../specled_ex", only: [:dev, :test], runtime: false}
```

Then run:

```bash
mix spec.assist
mix spec.check
```

When a cross-cutting policy needs to stay durable:

```bash
mix spec.adr.new repo.policy --title "Repository Policy"
```

For a fast local structural pass:

```bash
mix spec.verify
```

For coverage and brownfield frontier checks:

```bash
mix spec.report
```

For diff-aware governance enforcement:

```bash
mix spec.diffcheck
```

For stronger local or CI proof requirements:

```bash
mix spec.verify --min-strength linked
mix spec.check --min-strength executed
```

## Verification Strength

Verification strength is tracked per `(verification item, cover id)` claim.

- `claimed`
  - a known verification item exists and names the covered requirement or scenario id
- `linked`
  - a file-backed verification target exists and contains the covered id
- `executed`
  - a command verification ran and exited with status `0`

Minimum strength precedence is:

1. `--min-strength`
2. `spec-meta.verification_minimum_strength`
3. default `claimed`

If a claim is below its effective minimum, `spec.verify` emits
`verification_strength_below_minimum` as an error.

## Canonical State

`.spec/state.json` is written as a canonical artifact to keep diffs small:

- object keys are sorted recursively
- findings, claims, subjects, flattened index entries, and indexed ADRs are written in stable order
- volatile fields such as timestamps and absolute workspace roots are not persisted
- the file is only rewritten when the canonical bytes change

## ADRs And Git History

Use `.spec/decisions/*.md` only for durable cross-cutting ADRs. Do not add in-flight proposal folders under `.spec/`. Use Git branches, commits, and pull requests as the time dimension for how changes evolved.

## CI

GitHub Actions runs the same command through [`scripts/check_specs.sh`](scripts/check_specs.sh)
when `.spec/`, library code, or Mix configuration changes.
