ExUnit.start()

# Drift/refactor fixtures intentionally compile two versions of the same
# module name into temp dirs to exercise hash-stability and drift detection.
# The "redefining module" warning is the expected steady-state, not a bug.
Code.put_compiler_option(:ignore_module_conflict, true)

Code.require_file("../test_support/specled_ex_case.ex", __DIR__)
Code.require_file("../test_support/append_only_fixtures.ex", __DIR__)
