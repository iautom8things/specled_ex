defmodule SpecLedEx.Realization.ClosureTest do
  use ExUnit.Case, async: true
  @moduletag spec: ["specled.implementation_tier.closure_walks_tracer_edges", "specled.implementation_tier.hash_ref_composition", "specled.implementation_tier.ownership_rule", "specled.implementation_tier.shared_helper_accounting"]

  alias SpecLedEx.Realization.Closure

  # ---------------------------------------------------------------------------
  # Subject / world helpers
  # ---------------------------------------------------------------------------

  defp subject(id, bindings, surface \\ []) do
    %{id: id, surface: surface, impl_bindings: bindings}
  end

  defp world(subjects, edges, opts \\ []) do
    %{
      subjects: subjects,
      tracer_edges: edges,
      in_project?: Keyword.get(opts, :in_project?, fn _ -> true end),
      manifest: Keyword.get(opts, :manifest)
    }
  end

  describe "compute/2 — specled.implementation_tier.scenario.closure_walk_stops_at_boundary" do
    test "walk stops at subject boundary; other subject's MFA becomes a hash ref, not an inlined AST" do
      a = subject("A", ["Mod.A.foo/0"])
      b = subject("B", ["Mod.B.bar/0"])

      edges = %{
        {Mod.A, :foo, 0} => [{Mod.B, :bar, 0}],
        {Mod.B, :bar, 0} => [{Mod.B, :helper, 0}]
      }

      w = world([a, b], edges)

      closure = Closure.compute(a, w)

      assert closure.owned_mfas == [{Mod.A, :foo, 0}]
      assert closure.shared_mfas == []
      assert closure.referenced_subjects == ["B"]
      refute {Mod.B, :bar, 0} in closure.owned_mfas
      refute {Mod.B, :helper, 0} in closure.owned_mfas
    end
  end

  describe "compute/2 — specled.implementation_tier.scenario.shared_helper_inlined" do
    test "orphan helper is inlined into caller's closure" do
      a = subject("A", ["Mod.A.foo/0"])

      edges = %{
        {Mod.A, :foo, 0} => [{Helpers, :util, 0}]
      }

      w = world([a], edges)

      closure = Closure.compute(a, w)

      assert closure.owned_mfas == [{Mod.A, :foo, 0}]
      assert closure.shared_mfas == [{Helpers, :util, 0}]
      assert closure.referenced_subjects == []
    end

    test "shared helper is inlined into every caller's closure, not deduped across subjects" do
      a = subject("A", ["Mod.A.foo/0"])
      b = subject("B", ["Mod.B.bar/0"])

      edges = %{
        {Mod.A, :foo, 0} => [{Helpers, :util, 0}],
        {Mod.B, :bar, 0} => [{Helpers, :util, 0}]
      }

      w = world([a, b], edges)

      cla = Closure.compute(a, w)
      clb = Closure.compute(b, w)

      assert {Helpers, :util, 0} in cla.shared_mfas
      assert {Helpers, :util, 0} in clb.shared_mfas
    end
  end

  describe "compute/2 — cycle guard (specled.implementation_tier.closure_walks_tracer_edges)" do
    test "already-visited MFAs do not cause infinite recursion" do
      a = subject("A", ["Mod.A.foo/0"])

      edges = %{
        {Mod.A, :foo, 0} => [{Mod.A, :bar, 0}],
        {Mod.A, :bar, 0} => [{Mod.A, :foo, 0}]
      }

      w = world([a], edges)

      closure = Closure.compute(a, w)

      # Both MFAs are owned by A (no binding collision → surface ownership is
      # irrelevant because there's only one subject); the cycle is broken by
      # the visited set.
      assert {Mod.A, :foo, 0} in closure.owned_mfas
    end
  end

  describe "compute/2 — out-of-project stop" do
    test "callees in non-project modules are dropped from the walk" do
      a = subject("A", ["Mod.A.foo/0"])

      edges = %{
        {Mod.A, :foo, 0} => [{Kernel, :+, 2}]
      }

      in_project? = fn mod -> mod == Mod.A end
      w = world([a], edges, in_project?: in_project?)

      closure = Closure.compute(a, w)

      assert closure.owned_mfas == [{Mod.A, :foo, 0}]
      assert closure.shared_mfas == []
    end
  end

  describe "subject_for_mfa/2 — specled.implementation_tier.scenario.ownership_lexical_tiebreak" do
    test "binding match wins over surface" do
      aaa = subject("aaa", ["Shared.thing/0"], ["lib/shared.ex"])
      bbb = subject("bbb", [], ["lib/shared.ex"])

      w = world([aaa, bbb], %{})
      assert Closure.subject_for_mfa({Shared, :thing, 0}, w) == {:owned, "aaa"}
    end

    test "with no binding, surface match with lexical tiebreak picks aaa over bbb" do
      aaa = subject("aaa", [], ["lib/shared.ex"])
      bbb = subject("bbb", [], ["lib/shared.ex"])

      manifest = %{Shared => {:module, :elixir, ["lib/shared.ex"], %{}, %{}, %{}}}
      w = world([aaa, bbb], %{}, manifest: manifest)

      assert Closure.subject_for_mfa({Shared, :thing, 0}, w) == {:owned, "aaa"}
    end

    test "returns :shared when no subject owns the MFA (neither via binding nor surface)" do
      a = subject("A", ["Mod.A.foo/0"], ["lib/mod/a.ex"])

      manifest = %{Helpers => {:module, :elixir, ["lib/helpers.ex"], %{}, %{}, %{}}}
      w = world([a], %{}, manifest: manifest)

      assert Closure.subject_for_mfa({Helpers, :util, 0}, w) == :shared
    end
  end
end
