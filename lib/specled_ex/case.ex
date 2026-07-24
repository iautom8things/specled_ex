defmodule SpecLedEx.Case do
  @moduledoc """
  ExUnit case template that injects the per-test coverage boundary hook.

  For bare `use ExUnit.Case` modules. Phoenix-style apps should instead
  compose `setup {SpecLedEx.Coverage, :per_test_boundary}` into their own
  case templates.

  The hook no-ops unless `mix spec.cover.test --per-test` has armed the
  `:specled_ex, :spec_cover_run` seam with a `:boundary_table`, so it is
  safe to leave wired under plain `mix test`.

  See `docs/coverage.md` ("Wiring the per-test boundary hook").
  """

  use ExUnit.CaseTemplate

  setup {SpecLedEx.Coverage, :per_test_boundary}
end
