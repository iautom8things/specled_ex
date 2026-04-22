defmodule SampleProject.NoDebug do
  # covers: specled.expanded_behavior_tier.mixed_fixture_coverage
  @moduledoc """
  Fixture module compiled without beam debug_info.

  Used by `SpecLedEx.Realization.ExpandedBehavior` and
  `SpecLedEx.Realization.Typespecs` unit + integration tests to prove that the
  `@compile {:no_debug_info, true}` path degrades to `detector_unavailable`
  with reason `:debug_info_stripped` rather than raising.

  The sibling `Sample` module in this fixture retains default debug_info so
  the same fixture project exercises both the normal (hashable) path and the
  degraded (detector_unavailable) path.

  We set both `@compile {:no_debug_info, true}` (what the spec names
  literally) and `@compile {:debug_info, false}`. In modern Elixir only the
  latter strips the Elixir `:debug_info` chunk to `:none`; the former strips
  the Erlang-side `Abst` chunk. Together they guarantee the beam carries no
  recoverable debug_info across any supported Elixir version.
  """

  @compile {:no_debug_info, true}
  @compile {:debug_info, false}

  @spec fun() :: :ok
  def fun, do: :ok
end
