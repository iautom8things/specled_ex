# Make the suite hermetic to the host's git config so host commit-signing
# does not leak into fixture commits. On a dev machine with commit.gpgsign=true
# + 1Password's op-ssh-sign, every fixture commit would do IPC with the
# 1Password app (~2.5s signed vs ~0.3s unsigned), roughly doubling suite
# runtime. These env vars propagate to every git subprocess the test BEAM
# spawns; init_git_repo/1 already sets local user.name/user.email, so nothing
# from the global config is required.
System.put_env("GIT_CONFIG_GLOBAL", "/dev/null")
System.put_env("GIT_CONFIG_NOSYSTEM", "1")

# Every gate path arms SPECLED_COMMAND_OUTPUT_DIR (.claude/settings.json,
# `make check`, scripts/check_specs.sh) so a verification command that reddens
# once and never reproduces leaves its full output behind. This suite fails
# verification commands on purpose by the dozen — inheriting the gate's capture
# directory buries the one genuine capture under ~30 deliberate ones, and a
# forensic directory you have to search is most of the way back to not having
# one.
#
# Unsetting it here costs the gate nothing: the capture that matters is written
# by the OUTER `mix spec.check` BEAM about this suite's run, not by this BEAM
# about its own fixtures. Tests that exercise capture set their own directory,
# which also makes their cleanup exact rather than accidental — "unset" is now
# the deliberate baseline they restore to.
System.delete_env("SPECLED_COMMAND_OUTPUT_DIR")

Mix.shell(Mix.Shell.Process)

ExUnit.start()

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
