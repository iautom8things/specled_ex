defmodule SpecLedEx.Case do
  @moduledoc """
  ExUnit case template that injects the per-test coverage boundary hook.

  For bare `use ExUnit.Case` modules. Phoenix-style apps should instead
  compose `setup {SpecLedEx.Coverage, :per_test_boundary}` into their own
  case templates — in an adopter tree that direct reference is fine, since
  `mix xref` does not cross application boundaries.

  The hook no-ops unless `mix spec.cover.test --per-test` has armed the
  `:specled_ex, :spec_cover_run` seam with a `:boundary_table`, so it is
  safe to leave wired under plain `mix test`.

  See `docs/coverage.md` ("Wiring the per-test boundary hook").
  """

  use ExUnit.CaseTemplate

  # Block form (not `setup {SpecLedEx.Coverage, :per_test_boundary}`): the
  # tuple form puts the Coverage alias in module-body code and creates a
  # compile-connected xref edge, which the CI gate holds at zero.
  setup context do
    SpecLedEx.Coverage.per_test_boundary(context)
  end
end
