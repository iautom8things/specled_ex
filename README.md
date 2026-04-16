# SpecLedEx

Local helper package for Spec Led Development repositories.

The commands make the most sense when you group them by job instead of reading
them as one flat list.

## Session-Start Command

Use this when you are entering a repository, handing work to an agent, or
getting your bearings on an in-flight branch:

- `mix spec.prime`
  - prints one read-only session-start snapshot
  - combines workspace health, current-branch guidance, and the default local loop
  - skips `kind: command` execution by default; add `--run-commands` when you want executed proof in the embedded status summary

## Core Commands

These are the commands most maintainers should learn first:

- `mix spec.init`
  - scaffolds `.spec/` with starter files, including `README.md`, `AGENTS.md`, and `decisions/README.md`
  - in interactive runs, can also scaffold a local Skill for Spec Led Development
  - keeps `.spec` declarative and current-state only
- `mix spec.next`
  - reads the current Git change set and points at the next subject, proof, or ADR update to make
  - stays read-only in this release
  - supports `--bugfix` for regression-first guidance
- `mix spec.check`
  - runs the full local gate before you finish
  - updates derived state, validates current truth, and enforces branch coherence
  - enables `kind: command` execution by default; use `--no-run-commands` to opt out

## Occasional Commands

These are helpful, but they are not part of the default local loop:

- `mix spec.status`
  - summarizes source, guide, and test coverage, verification strength, weak spots, and ADR usage
  - useful for brownfield adoption and maintenance review
- `mix spec.decision.new`
  - scaffolds a durable ADR under `.spec/decisions/`
  - use it only when the change is durable and cross-cutting

## Advanced Commands

These are low-level plumbing commands. They are useful for debugging and tooling,
but they are not where a junior developer should start:

- `mix spec.index`
  - reads `.spec/specs/*.spec.md` and `.spec/decisions/*.md`
  - updates `.spec/state.json` with subject and ADR index data
- `mix spec.validate`
  - validates authored specs, updates `.spec/state.json`, and exits non-zero when the verification report fails
  - keeps `kind: command` verification execution off by default for fast local runs

## Default Local Loop

<!-- covers: specled.package.default_local_loop -->

Use one small loop by default:

1. if you are entering the repo or handing work to an agent, run `mix spec.prime --base HEAD`
2. make the code, test, or docs change
3. add or tighten the smallest test when behavior changed
4. annotate that test with `@tag spec: "<requirement.id>"` when test-tag scanning is enabled (see below)
5. run `mix spec.next`
6. if it says `needs subject updates`, update the named subject
7. if it says `needs decision update`, add or revise an ADR only when the change is durable and cross-cutting
8. when it says `ready for check`, run `mix spec.check --base ...`

For bug fixes:

```bash
mix spec.next --bugfix
```

For one focused workset inside a longer-lived branch:

```bash
mix spec.next --base main --since <checkpoint>
```

Add `--verbose` when you want the raw changed-file lists in the guidance output.
Add `--json` when an editor, script, or agent needs the structured report.

## Local Usage

Add as a path dependency in another project:

```elixir
{:spec_led_ex, path: "../specled_ex", only: [:dev, :test], runtime: false}
```

Then run:

```bash
mix spec.prime --base HEAD
mix spec.next
mix spec.check --base HEAD
```

When a cross-cutting policy needs to stay durable:

```bash
mix spec.decision.new repo.policy --title "Repository Policy"
```

For coverage and brownfield frontier checks:

```bash
mix spec.status
```

For a fast local structural pass or package debugging:

```bash
mix spec.validate
```

For stronger local or CI proof requirements:

```bash
mix spec.validate --min-strength linked
mix spec.check --min-strength executed
```

To override test-tag scanning for a single run:

```bash
mix spec.check --test-tags
mix spec.validate --no-test-tags
```

## Test-Tag Scanning

Test-tag scanning links requirements to the tests that cover them by looking
for `@tag spec: "<requirement.id>"` annotations in your ExUnit files, without
running the suite. Adoption is opt-in per-workspace.

### Getting Started With Test Tags

1. Enable scanning in `.spec/config.yml` (scaffolded by `mix spec.init`):

   ```yaml
   test_tags:
     enabled: true
     paths:
       - test
     enforcement: warning
   ```

2. Tag each ExUnit test with the requirement id it covers:

   ```elixir
   defmodule Billing.InvoiceTest do
     use ExUnit.Case

     @tag spec: "billing.invoice"
     test "emits an invoice line per sku" do
       assert Billing.invoice(order).lines == [...]
     end
   end
   ```

3. Run `mix spec.check`. The scanner walks the configured paths, builds a
   `requirement_id → [tests]` map, and the verifier emits findings for any
   `must` requirement with no backing annotation.

4. When coverage is complete, graduate to `enforcement: error` to make the
   check a hard gate.

### Supported Annotation Shapes

```elixir
# single id (string)
@tag spec: "auth.login"
test "logs in", do: ...

# keyword list (other keys are ignored)
@tag [spec: "auth.logout", timeout: 5_000]
test "logs out", do: ...

# list of ids (the test covers multiple requirements)
@tag spec: ["a.one", "a.two"]
test "covers both", do: ...

# module-wide tag (attaches to every test in the module)
defmodule DomainTest do
  use ExUnit.Case
  @moduletag spec: "domain.root"

  test "one", do: ...
  test "two", do: ...
end
```

Annotations whose value is a module attribute, variable, or other non-literal
expression are reported as `tag_dynamic_value_skipped` findings so the gap is
visible.

### `.spec/config.yml` Schema

| Key                      | Type          | Default     | Description                                                                        |
|--------------------------|---------------|-------------|------------------------------------------------------------------------------------|
| `test_tags.enabled`      | boolean       | `false`     | When `true`, `mix spec.check` and friends scan `paths` for `@tag spec:` and emit tag findings. |
| `test_tags.paths`        | list of paths | `["test"]`  | Directories (or individual files) the scanner walks when enabled.                  |
| `test_tags.enforcement`  | `warning` \| `error` | `warning`   | Severity of `requirement_without_test_tag` and `verification_cover_untagged` findings. |

Unknown `enforcement` values fall back to the default and log a warning. A
missing or malformed `.spec/config.yml` degrades to defaults.

### CLI Overrides

`mix spec.check` and `mix spec.validate` accept `--test-tags` /
`--no-test-tags` to override the workspace default for a single invocation:

```bash
# force-enable for a one-off run
mix spec.check --test-tags

# force-disable for a one-off run, even when config enables it
mix spec.validate --no-test-tags
```

Precedence: CLI flag > `.spec/config.yml` > built-in default.

### Finding Codes

| Code                                        | Severity         | Emitted by          | Meaning                                                                           |
|---------------------------------------------|------------------|---------------------|-----------------------------------------------------------------------------------|
| `requirement_without_test_tag`              | warning \| error | verifier            | A `must` requirement has no backing `@tag spec` annotation.                       |
| `verification_cover_untagged`               | warning \| error | verifier            | A `test_file`/`test` verification target does not annotate the id it covers.      |
| `tag_scan_parse_error`                      | warning          | verifier            | The scanner could not parse a test file as Elixir.                                |
| `tag_dynamic_value_skipped`                 | warning          | verifier            | An `@tag spec:` value was not a literal string or list of strings.                |
| `branch_guard_requirement_without_test_tag` | warning \| error | `mix spec.check`    | A `must` requirement new on this branch has no backing `@tag spec` annotation.    |

The `warning|error` severity is driven by `test_tags.enforcement`.

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

If a claim is below its effective minimum, `spec.validate` emits
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
