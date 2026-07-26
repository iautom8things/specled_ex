# Make the suite hermetic to the host's git config so host commit-signing
# does not leak into fixture commits. On a dev machine with commit.gpgsign=true
# + 1Password's op-ssh-sign, every fixture commit would do IPC with the
# 1Password app (~2.5s signed vs ~0.3s unsigned), roughly doubling suite
# runtime. These env vars propagate to every git subprocess the test BEAM
# spawns; init_git_repo/1 already sets local user.name/user.email, so nothing
# from the global config is required.
System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")
System.put_env("GIT_CONFIG_NOSYSTEM", "1")

Mix.shell(Mix.Shell.Process)

# Per-test timeout raised from the 60s default: under a loaded machine
# (parallel orchestration running several suites at once) the
# subprocess-heavy tests — nested verifier runs, git-backed fixtures — slow
# down far more than CPU-bound ones, and a 60s kill turns machine load into a
# red `mix spec.check` gate (specled_-odl). The tagged_tests leg's own
# command budget (verification.command_timeout_ms, 400s) still bounds the
# whole suite, so a genuine hang is caught regardless.
ExUnit.start(timeout: 120_000)

# Drift/refactor fixtures intentionally compile two versions of the same
# module name into temp dirs to exercise hash-stability and drift detection.
# The "redefining module" warning is the expected steady-state, not a bug.
Code.put_compiler_option(:ignore_module_conflict, true)

# Legacy test_support/ at the repo root is loaded via Code.require_file/2 —
# it is intentionally NOT in mix.exs `elixirc_paths` so the helpers stay
# inert outside test runs.
Code.require_file("../test_support/specled_ex_fixture_case.ex", __DIR__)
Code.require_file("../test_support/append_only_fixtures.ex", __DIR__)

# New test_support modules live under `test/test_support/` and are compiled
# by Mix via the `elixirc_paths(:test)` clause in `mix.exs`. They do not
# need explicit `Code.require_file` calls — adding one would re-define the
# module and emit a "redefining module" warning. Add new helpers to
# `test/test_support/` and they will be available to every test.
:ok
