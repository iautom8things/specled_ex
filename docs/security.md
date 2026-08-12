# Security

Security guidance for running SpecLedEx in continuous integration.

<!-- covers: specled.package.command_execution_trust_policy -->

## Repository-authored verification commands

`kind: command` verification targets are shell commands stored in the
repository's `.spec/specs/*.spec.md` files. `mix spec.check` and `mix spec.status`
both execute enabled command targets by default; pass `--no-run-commands` to
either to suppress that. Only
`mix spec.prime` and `mix spec.validate` are opt-in, via `--run-commands`.

This is intentional: executable verification lets a repository define the
proof its own requirements need. It is also a trust boundary. Anyone who can
change a spec file can change the shell that the CI runner executes. A pull
request from a fork must therefore be treated like any other untrusted change
to a build script, test helper, or workflow input.

SpecLedEx does not sandbox command targets, inspect them for safe syntax, or
maintain an allowlist. Do not use command execution as an approval mechanism
for code that has not already crossed your repository's trust boundary.

## Recommended public-repository policy

Split pull-request verification into untrusted and trusted lanes:

1. On every fork pull request, run the structural gate with
   `mix spec.check --no-run-commands`. Give the job read-only permissions and
   no secrets.
2. Run command targets only for a revision your project trusts, such as a
   same-repository branch or a reviewed commit copied to a maintainer-controlled
   branch. Keep that job least-privileged and avoid secrets unless a particular
   verification has a documented need for them.
3. Require the trusted, command-executing result before merge when executed
   verification is part of your merge policy.

For GitHub Actions, a fork-aware split can keep both lanes visible:

```yaml
permissions:
  contents: read

jobs:
  structural:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "27"
          elixir-version: "1.18"
      - run: mix deps.get
      - run: mix spec.check --no-run-commands --base origin/main

  commands:
    if: github.event.pull_request.head.repo.full_name == github.repository
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: erlef/setup-beam@v1
        with:
          otp-version: "27"
          elixir-version: "1.18"
      - run: mix deps.get
      - run: mix spec.check --base origin/main
```

Adjust the setup and base-ref fetch to match your project. The security
property is the lane boundary: a fork-controlled revision does not enter the
job that executes repository-authored verification commands.

Do not use `pull_request_target` to check out a fork's head commit and then run
`mix spec.check`, Mix setup, dependency installation, tests, or any other
repository-controlled command. That event runs in the base repository's
security context; combining it with an untrusted checkout can expose its token
and secrets. Use it only for operations that do not execute or source content
from the pull request.

GitHub's workflow approval controls can add a useful human gate, but approval
should mean that a maintainer reviewed the exact revision that will execute.
If new commits arrive, review the new revision before allowing the trusted lane
to run.

## What `--no-run-commands` does and does not do

`--no-run-commands` disables both executing verification kinds: `kind: command`
targets, and `kind: tagged_tests`, which spawns `mix test` over the repository's
own test code. Structural validation, branch reconciliation, realization-drift
checks, and test-tag consistency still run.

It does not stop the revision's own code from being compiled. `mix spec.check`
declares `@requirements ["app.config"]`, which evaluates the repository's
`mix.exs` and compiles the project before any check runs. Even with
`--no-run-commands`, the structural lane executes the revision's compile-time
code — module bodies, macros, and compiler tracers. Size that job's permissions
accordingly: it is an untrusted-code job, not a parsing job.

It is not a general-purpose sandbox for an untrusted Elixir project. CI steps
such as dependency installation, compilation, tests, custom Mix aliases, and
coverage commands can execute repository-controlled code independently of
SpecLedEx command targets. Apply the same fork-PR trust policy to those steps
and to caches, artifacts, credentials, and self-hosted runners they can reach.

For private repositories or trusted contributor branches, running
`mix spec.check` with commands enabled is the normal pre-merge gate. The point
of the split is not to weaken verification; it is to execute repository-defined
proof only after the revision is trusted and in a runner context sized for that
trust.
