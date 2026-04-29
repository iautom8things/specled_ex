defmodule SpecLedEx.Realization.ImplementationTest do
  use ExUnit.Case, async: false
  @moduletag spec: ["specled.implementation_tier.closure_walks_tracer_edges"]

  alias SpecLedEx.Realization.{HashStore, Implementation}

  # ---------------------------------------------------------------------------
  # Disk-compiled fixtures — we need real beam modules so Binding.resolve can
  # extract canonical AST for owned/shared MFAs during hash composition.
  # ---------------------------------------------------------------------------
  setup_all do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_impl_fixtures_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    source_path = Path.join(tmp_dir, "impl_fixtures.ex")

    File.write!(source_path, """
    defmodule SpecLedEx.ImplFixtures.A do
      def foo(x), do: SpecLedEx.ImplFixtures.B.bar(x) + 1
    end

    defmodule SpecLedEx.ImplFixtures.B do
      def bar(x), do: SpecLedEx.ImplFixtures.B.helper(x)
      def helper(x), do: x * 2
    end

    defmodule SpecLedEx.ImplFixtures.Solo do
      def run(x), do: SpecLedEx.ImplFixtures.Helpers.util(x)
    end

    defmodule SpecLedEx.ImplFixtures.Helpers do
      def util(x), do: x + 100
    end

    defmodule SpecLedEx.ImplFixtures.WrapperShape do
      def guarded_tuple(a, b) when is_atom(a), do: {a, b}
      def guarded_tuple(a, b), do: {b, a}
    end
    """)

    {:ok, _mods, _warns} = Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir, return_diagnostics: true)
    :code.add_patha(String.to_charlist(tmp_dir))

    for mod <- [
          SpecLedEx.ImplFixtures.A,
          SpecLedEx.ImplFixtures.B,
          SpecLedEx.ImplFixtures.Solo,
          SpecLedEx.ImplFixtures.Helpers,
          SpecLedEx.ImplFixtures.WrapperShape
        ] do
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_file(mod)
    end

    on_exit(fn ->
      :code.del_path(String.to_charlist(tmp_dir))
      File.rm_rf!(tmp_dir)
    end)

    {:ok, fixture_dir: tmp_dir}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "specled_impl_run_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # ---------------------------------------------------------------------------
  # Fixture world — the "sample project" under test for the unit suite.
  # ---------------------------------------------------------------------------
  defp fixture_world do
    subject_a = %{
      id: "A",
      surface: [],
      impl_bindings: ["SpecLedEx.ImplFixtures.A.foo/1"]
    }

    subject_b = %{
      id: "B",
      surface: [],
      impl_bindings: ["SpecLedEx.ImplFixtures.B.bar/1"]
    }

    edges = %{
      {SpecLedEx.ImplFixtures.A, :foo, 1} => [{SpecLedEx.ImplFixtures.B, :bar, 1}],
      {SpecLedEx.ImplFixtures.B, :bar, 1} => [{SpecLedEx.ImplFixtures.B, :helper, 1}]
    }

    in_project? = fn mod -> mod in [SpecLedEx.ImplFixtures.A, SpecLedEx.ImplFixtures.B] end

    %{
      subjects: [subject_a, subject_b],
      tracer_edges: edges,
      in_project?: in_project?
    }
  end

  defp solo_world(helper_ast_or_nil \\ nil) do
    solo = %{
      id: "Solo",
      surface: [],
      impl_bindings: ["SpecLedEx.ImplFixtures.Solo.run/1"]
    }

    edges = %{
      {SpecLedEx.ImplFixtures.Solo, :run, 1} => [{SpecLedEx.ImplFixtures.Helpers, :util, 1}]
    }

    in_project? = fn mod ->
      mod in [SpecLedEx.ImplFixtures.Solo, SpecLedEx.ImplFixtures.Helpers]
    end

    _ = helper_ast_or_nil

    %{
      subjects: [solo],
      tracer_edges: edges,
      in_project?: in_project?
    }
  end

  describe "hash_for_subject/3 — specled.implementation_tier.hash_ref_composition" do
    @tag spec: ["specled.implementation_tier.hash_ref_composition"]
    test "normalizes Binding.resolve beam wrapper clauses before hashing" do
      subject = %{
        id: "Wrapped",
        surface: [],
        impl_bindings: ["SpecLedEx.ImplFixtures.WrapperShape.guarded_tuple/2"]
      }

      world = %{subjects: [subject], tracer_edges: %{}, in_project?: fn _ -> true end}

      assert {:ok, hash} = Implementation.hash_for_subject(subject, world)
      assert is_binary(hash)
    end

    test "hash input for A includes a 'subject:B:hash:...' string, not B's canonical AST" do
      world = fixture_world()

      {:ok, a_hash} =
        Implementation.hash_for_subject(
          Enum.find(world.subjects, &(&1.id == "A")),
          world
        )

      {:ok, b_hash} =
        Implementation.hash_for_subject(
          Enum.find(world.subjects, &(&1.id == "B")),
          world
        )

      assert is_binary(a_hash)
      assert is_binary(b_hash)

      # Stability under a re-computation.
      {:ok, a_hash_again} =
        Implementation.hash_for_subject(
          Enum.find(world.subjects, &(&1.id == "A")),
          world
        )

      assert a_hash == a_hash_again
    end
  end

  describe "hash_for_subject/3 — Cargo composition: cross-subject hash reference" do
    test "A's hash changes when B's referenced hash marker changes" do
      world1 = fixture_world()

      {:ok, a_hash_1} =
        Implementation.hash_for_subject(
          Enum.find(world1.subjects, &(&1.id == "A")),
          world1
        )

      # Re-wire B's closure so B's hash input differs: point B.bar at a
      # different callee (still in-project via helper). Since Cargo-style
      # references embed B's current hash in A's hash input, A's hash must
      # flip even though A's own owned MFAs are unchanged.
      world2 =
        update_in(world1.tracer_edges, fn edges ->
          Map.put(edges, {SpecLedEx.ImplFixtures.B, :bar, 1}, [])
        end)

      {:ok, a_hash_2} =
        Implementation.hash_for_subject(
          Enum.find(world2.subjects, &(&1.id == "A")),
          world2
        )

      refute a_hash_1 == a_hash_2
    end
  end

  describe "hash_for_subject/3 — specled.implementation_tier.scenario.shared_helper_inlined" do
    test "shared helper's AST is inlined — its body changes ripple into the caller's hash" do
      # Build a world where Solo.run/1 calls Helpers.util/1 (Helpers is not
      # claimed by any subject).
      world = solo_world()
      solo = hd(world.subjects)

      {:ok, hash_before} = Implementation.hash_for_subject(solo, world)
      {:ok, hash_again} = Implementation.hash_for_subject(solo, world)
      assert hash_before == hash_again

      # Now re-define Helpers.util/1 with a different body and reload. The
      # orchestrator re-reads the beam during composition, so the hash flips.
      tmp_dir =
        Path.join(
          System.tmp_dir!(),
          "specled_impl_helpers_rewrite_#{:erlang.unique_integer([:positive])}"
        )

      File.mkdir_p!(tmp_dir)
      source_path = Path.join(tmp_dir, "helpers_v2.ex")

      File.write!(source_path, """
      defmodule SpecLedEx.ImplFixtures.Helpers do
        def util(x), do: x * 17 + 3
      end
      """)

      {:ok, _mods, _warns} = Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir, return_diagnostics: true)
      :code.add_patha(String.to_charlist(tmp_dir))

      :code.purge(SpecLedEx.ImplFixtures.Helpers)
      :code.delete(SpecLedEx.ImplFixtures.Helpers)
      {:module, SpecLedEx.ImplFixtures.Helpers} = :code.load_file(SpecLedEx.ImplFixtures.Helpers)

      on_exit(fn ->
        :code.del_path(String.to_charlist(tmp_dir))
        File.rm_rf!(tmp_dir)
      end)

      {:ok, hash_after} = Implementation.hash_for_subject(solo, world)
      refute hash_before == hash_after
    end
  end

  describe "hash_for_subject/3 — dangling binding" do
    test "returns {:error, {:dangling_bindings, [...]}} when a declared binding does not exist" do
      subject = %{
        id: "Ghost",
        surface: [],
        impl_bindings: ["SpecLedEx.ImplFixtures.DoesNotExist.nope/0"]
      }

      world = %{subjects: [subject], tracer_edges: %{}, in_project?: fn _ -> true end}

      assert {:error, {:dangling_bindings, ["SpecLedEx.ImplFixtures.DoesNotExist.nope/0"]}} =
               Implementation.hash_for_subject(subject, world)
    end
  end

  describe "run/4 — drift finding" do
    test "emits branch_guard_realization_drift when committed subject-hash differs", %{root: root} do
      world = fixture_world()
      subject_a = Enum.find(world.subjects, &(&1.id == "A"))

      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            subject_a.id => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      findings = Implementation.run(world.subjects, world, nil, root: root)

      drift =
        Enum.find(findings, fn f ->
          f["code"] == "branch_guard_realization_drift" and f["subject_id"] == "A"
        end)

      assert drift != nil, "expected drift finding, got: #{inspect(findings)}"
      assert drift["tier"] == "implementation"
    end

    test "no drift finding when current hash matches committed", %{root: root} do
      world = fixture_world()
      subject_a = Enum.find(world.subjects, &(&1.id == "A"))
      subject_b = Enum.find(world.subjects, &(&1.id == "B"))

      {:ok, a_hash} = Implementation.hash_for_subject(subject_a, world)
      {:ok, b_hash} = Implementation.hash_for_subject(subject_b, world)

      :ok =
        HashStore.write(root, %{
          "implementation" => %{
            "A" => %{
              "hash" => Base.encode16(a_hash, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            },
            "B" => %{
              "hash" => Base.encode16(b_hash, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      findings = Implementation.run(world.subjects, world, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end

    test "no drift finding when no committed hash exists (first commit)", %{root: root} do
      world = fixture_world()
      findings = Implementation.run(world.subjects, world, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end
  end

  describe "run/4 — dangling finding" do
    test "emits branch_guard_dangling_binding when a declared implementation MFA is missing", %{
      root: root
    } do
      ghost = %{
        id: "Ghost",
        surface: [],
        impl_bindings: ["SpecLedEx.ImplFixtures.DoesNotExist.nope/0"]
      }

      world = %{subjects: [ghost], tracer_edges: %{}, in_project?: fn _ -> true end}

      findings = Implementation.run([ghost], world, nil, root: root)

      dangling = Enum.find(findings, &(&1["code"] == "branch_guard_dangling_binding"))
      assert dangling != nil, "expected dangling finding, got: #{inspect(findings)}"
      assert dangling["subject_id"] == "Ghost"
      assert dangling["tier"] == "implementation"
    end
  end

  describe "run/4 — umbrella graceful degrade" do
    test "emits a single detector_unavailable finding when umbrella? is true", %{root: root} do
      findings = Implementation.run([], nil, nil, root: root, umbrella?: true)

      assert length(findings) == 1
      [finding] = findings
      assert finding["code"] == "detector_unavailable"
      assert finding["reason"] == "umbrella_unsupported"
    end
  end
end
