ExUnit.start()

# Drift/refactor fixtures intentionally compile two versions of the same
# module name into temp dirs to exercise hash-stability and drift detection.
# The "redefining module" warning is the expected steady-state, not a bug.
Code.put_compiler_option(:ignore_module_conflict, true)

# Legacy test_support/ at the repo root is loaded via Code.require_file/2 —
# it is intentionally NOT in mix.exs `elixirc_paths` so the helpers stay
# inert outside test runs.
Code.require_file("../test_support/specled_ex_case.ex", __DIR__)
Code.require_file("../test_support/append_only_fixtures.ex", __DIR__)

# New test_support modules live under `test/test_support/` and are compiled
# by Mix via the `elixirc_paths(:test)` clause in `mix.exs`. They do not
# need explicit `Code.require_file` calls — adding one would re-define the
# module and emit a "redefining module" warning. Add new helpers to
# `test/test_support/` and they will be available to every test.
:ok
