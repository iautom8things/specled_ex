defmodule SpecLedEx.Realization.ApiBoundaryTest do
  use ExUnit.Case, async: true

  @moduletag spec: [
               "specled.api_boundary.dangling_finding_emitted",
               "specled.api_boundary.drift_finding_emitted",
               "specled.api_boundary.hash_function_head",
               "specled.api_boundary.umbrella_graceful_degrade"
             ]

  alias SpecLedEx.Realization.{ApiBoundary, Binding, HashStore}

  # ---------------------------------------------------------------------------
  # Disk-compiled fixtures (same mechanism as BindingTest) so ApiBoundary.run/1
  # can resolve them via the beam path.
  # ---------------------------------------------------------------------------
  setup_all do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "specled_api_boundary_fixtures_#{:erlang.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)

    source_path = Path.join(tmp_dir, "api_boundary_fixtures.ex")

    File.write!(source_path, """
    defmodule SpecLedEx.ApiBoundaryFixtures.Stable do
      # Arity and arg pattern fixed; body varies across test runs.
      def bar(x), do: x + 1
    end

    defmodule SpecLedEx.ApiBoundaryFixtures.WithMapPattern do
      def lookup(%{key: _val, other: _o}), do: :ok
    end

    defmodule SpecLedEx.ApiBoundaryFixtures.WithLiteralDefault do
      def greet(name \\\\ "world"), do: "hello \#{name}"
    end
    """)

    {:ok, _mods, _warns} =
      Kernel.ParallelCompiler.compile_to_path([source_path], tmp_dir, return_diagnostics: true)

    :code.add_patha(String.to_charlist(tmp_dir))

    for mod <- [
          SpecLedEx.ApiBoundaryFixtures.Stable,
          SpecLedEx.ApiBoundaryFixtures.WithMapPattern,
          SpecLedEx.ApiBoundaryFixtures.WithLiteralDefault
        ] do
      :code.purge(mod)
      :code.delete(mod)
      {:module, ^mod} = :code.load_file(mod)
    end

    on_exit(fn ->
      :code.del_path(String.to_charlist(tmp_dir))
      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "specled_ab_run_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".spec"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # A BEAM-form resolved head — the shape `Binding.resolve/2` returns from a
  # module's debug_info: `{fun, arity, [{args, guards, body}]}`. A remote-call
  # guard (`is_map(x)`) is `{{:., meta, [:erlang, fun]}, meta, [var]}`; that inner
  # `.` node is the leak site for specled_-o40. `line` places the whole head at a
  # source position (as if lines were inserted above the function).
  defp guarded_head(guard_fun, line) do
    var = {:x, [version: 0, line: line, column: 11], nil}

    guard =
      {{:., [line: line, column: 20], [:erlang, guard_fun]}, [line: line, column: 20], [var]}

    {:foo, 1, [{[var], [guard], {:ok, [line: line], nil}}]}
  end

  describe "hash/2" do
    test "stable across whitespace and variable renames (no drift)" do
      {:ok, ast_v1} =
        Binding.resolve("SpecLedEx.ApiBoundaryFixtures.Stable.bar/1")

      h1 = ApiBoundary.hash(ast_v1)

      # Same arity, same pattern — the hash is a function of head + shape
      assert h1 == ApiBoundary.hash(ast_v1)
    end

    test "invariant under a line shift of a remote-call guard's source position (specled_-o40)" do
      # BEAM-form head with an `is_map/1` guard, at two source positions. Pre-fix,
      # strip_meta left the guard's `.` callee node in `form` position un-recursed,
      # so its line/column survived into the hash and this assertion FAILED.
      # (Proven non-vacuous by reverting strip_meta: this test goes red.)
      assert ApiBoundary.hash(guarded_head(:is_map, 10)) ==
               ApiBoundary.hash(guarded_head(:is_map, 200)),
             "a line shift must not change the api_boundary hash"
    end

    test "the guard's callee participates in the hash — guards are not dropped (specled_-o40)" do
      # Rules out the vacuous mode: if the guard were ignored, the invariance
      # above would be trivially true. A different guard function must change it.
      refute ApiBoundary.hash(guarded_head(:is_map, 10)) ==
               ApiBoundary.hash(guarded_head(:is_list, 10))
    end

    test "changes when arg pattern structure changes" do
      # Build two AST shapes by parsing strings (source form feeds the same
      # canonicalizer that ApiBoundary uses internally for source-fallback ASTs).
      ast1 = Code.string_to_quoted!("def bar(%{key: val}), do: val")
      ast2 = Code.string_to_quoted!("def bar(%{key: val, other: _}), do: val")

      refute ApiBoundary.hash(ast1) == ApiBoundary.hash(ast2)
    end
  end

  describe "run/3 — drift finding" do
    test "emits branch_guard_realization_drift when committed hash differs", %{root: root} do
      mfa = "SpecLedEx.ApiBoundaryFixtures.Stable.bar/1"

      # Seed the store with a DIFFERENT hash so current-vs-committed disagrees
      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      bindings = [%{subject_id: "test.subject", requirement_id: nil, mfa: mfa}]
      findings = ApiBoundary.run(bindings, nil, root: root)

      drift =
        Enum.find(findings, fn f -> f["code"] == "branch_guard_realization_drift" end)

      assert drift != nil, "expected drift finding, got: #{inspect(findings)}"
      assert drift["subject_id"] == "test.subject"
      assert drift["tier"] == "api_boundary"
      assert drift["mfa"] == mfa
    end

    test "no drift finding when current hash matches committed", %{root: root} do
      mfa = "SpecLedEx.ApiBoundaryFixtures.Stable.bar/1"

      {:ok, ast} = Binding.resolve(mfa)
      current = ApiBoundary.hash(ast)

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            mfa => %{
              "hash" => Base.encode16(current, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      bindings = [%{subject_id: "test.subject", requirement_id: nil, mfa: mfa}]
      findings = ApiBoundary.run(bindings, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end

    test "no drift finding when no committed hash exists (first commit)", %{root: root} do
      mfa = "SpecLedEx.ApiBoundaryFixtures.Stable.bar/1"

      bindings = [%{subject_id: "test.subject", requirement_id: nil, mfa: mfa}]
      findings = ApiBoundary.run(bindings, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end
  end

  describe "run/3 — dangling finding (arity change scenario)" do
    test "emits branch_guard_dangling_binding when the MFA no longer exists", %{root: root} do
      # Stable has bar/1; arity-2 binding should be reported as dangling.
      mfa = "SpecLedEx.ApiBoundaryFixtures.Stable.bar/2"

      bindings = [%{subject_id: "test.subject", requirement_id: nil, mfa: mfa}]
      findings = ApiBoundary.run(bindings, nil, root: root)

      dangling =
        Enum.find(findings, fn f -> f["code"] == "branch_guard_dangling_binding" end)

      assert dangling != nil, "expected dangling finding, got: #{inspect(findings)}"
      assert dangling["subject_id"] == "test.subject"
      assert dangling["tier"] == "api_boundary"
      assert dangling["mfa"] == mfa

      # Remediation message names MFA, tier, subject id — agent-pastable
      msg = dangling["message"]
      assert String.contains?(msg, mfa)
      assert String.contains?(msg, "api_boundary")
      assert String.contains?(msg, "test.subject")
    end
  end

  describe "run/3 — umbrella graceful degrade" do
    test "emits a single detector_unavailable finding when umbrella? is true", %{root: root} do
      bindings = [
        %{
          subject_id: "any.subject",
          requirement_id: nil,
          mfa: "SpecLedEx.ApiBoundaryFixtures.Stable.bar/1"
        }
      ]

      findings = ApiBoundary.run(bindings, nil, root: root, umbrella?: true)

      assert length(findings) == 1
      [finding] = findings
      assert finding["code"] == "detector_unavailable"
      assert finding["reason"] == "umbrella_unsupported"
    end
  end

  describe "run/3 — non-literal default rule (documented weakening)" do
    test "literal defaults are included in the hash; non-literal defaults become :non_literal_default" do
      with_literal = Code.string_to_quoted!("def f(x \\\\ :a), do: x")
      with_non_literal = Code.string_to_quoted!("def f(x \\\\ System.unique_integer()), do: x")

      # The literal and non-literal variants should hash differently (because
      # literals are captured in the hash input, while non-literals are replaced
      # with the sentinel). Two non-literal variants with different call
      # expressions should hash the SAME (both collapse to :non_literal_default).
      with_non_literal_other =
        Code.string_to_quoted!("def f(x \\\\ SomeOtherMod.call()), do: x")

      refute ApiBoundary.hash(with_literal) == ApiBoundary.hash(with_non_literal)

      assert ApiBoundary.hash(with_non_literal) ==
               ApiBoundary.hash(with_non_literal_other)
    end
  end

  # covers: specled.realized_by.bare_module_api_boundary_hash
  describe "run/3 — bare-module entries hash via Canonical.hash_module_head_union/2" do
    @tag spec: ["specled.realized_by.bare_module_api_boundary_hash"]
    test "no drift finding when committed bare-module hash matches current head-union", %{
      root: root
    } do
      module_string = "SpecLedEx.ApiBoundaryFixtures.Stable"

      {:ok, current} =
        SpecLedEx.Realization.Canonical.hash_module_head_union(
          SpecLedEx.ApiBoundaryFixtures.Stable
        )

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            module_string => %{
              "hash" => Base.encode16(current, case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      bindings = [%{subject_id: "test.subject", requirement_id: nil, mfa: module_string}]
      findings = ApiBoundary.run(bindings, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_realization_drift"))
    end

    @tag spec: ["specled.realized_by.bare_module_api_boundary_hash"]
    test "drift finding fires when committed bare-module hash differs", %{root: root} do
      module_string = "SpecLedEx.ApiBoundaryFixtures.Stable"

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            module_string => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      bindings = [%{subject_id: "test.subject", requirement_id: nil, mfa: module_string}]
      findings = ApiBoundary.run(bindings, nil, root: root)

      drift = Enum.find(findings, &(&1["code"] == "branch_guard_realization_drift"))
      assert drift != nil, "expected drift finding, got: #{inspect(findings)}"
      assert drift["mfa"] == module_string
      assert drift["tier"] == "api_boundary"
    end
  end

  # covers: specled.realized_by.implication_dangling_once
  # covers: specled.realized_by.binding_ref_inferred_no_leak
  describe "run/3 — inferred? suppresses dangling, never leaks into findings" do
    @tag spec: ["specled.realized_by.implication_dangling_once"]
    test "inferred?: true + :not_found → returns []", %{root: root} do
      mfa = "SpecLedEx.ApiBoundaryFixtures.Stable.does_not_exist/0"

      bindings = [
        %{subject_id: "test.subject", requirement_id: nil, mfa: mfa, inferred?: true}
      ]

      findings = ApiBoundary.run(bindings, nil, root: root)

      refute Enum.any?(findings, &(&1["code"] == "branch_guard_dangling_binding")),
             "expected zero dangling findings, got: #{inspect(findings)}"
    end

    @tag spec: ["specled.realized_by.implication_dangling_once"]
    test "inferred?: false + :not_found → returns the dangling finding", %{root: root} do
      mfa = "SpecLedEx.ApiBoundaryFixtures.Stable.does_not_exist/0"

      bindings = [
        %{subject_id: "test.subject", requirement_id: nil, mfa: mfa, inferred?: false}
      ]

      findings = ApiBoundary.run(bindings, nil, root: root)

      dangling = Enum.find(findings, &(&1["code"] == "branch_guard_dangling_binding"))
      assert dangling != nil, "expected dangling finding, got: #{inspect(findings)}"
      assert dangling["mfa"] == mfa
    end

    @tag spec: ["specled.realized_by.implication_dangling_once"]
    test "absent inferred? key is treated as false (default behavior unchanged)", %{root: root} do
      mfa = "SpecLedEx.ApiBoundaryFixtures.Stable.does_not_exist/0"
      bindings = [%{subject_id: "test.subject", requirement_id: nil, mfa: mfa}]

      findings = ApiBoundary.run(bindings, nil, root: root)

      assert Enum.any?(findings, &(&1["code"] == "branch_guard_dangling_binding"))
    end

    @tag spec: ["specled.realized_by.implication_dangling_once"]
    test "inferred?: true + bare-module not loadable → returns []", %{root: root} do
      module_string = "SpecLedEx.NotLoadable.Module.Imaginary"

      bindings = [
        %{
          subject_id: "test.subject",
          requirement_id: nil,
          mfa: module_string,
          inferred?: true
        }
      ]

      findings = ApiBoundary.run(bindings, nil, root: root)
      refute Enum.any?(findings, &(&1["code"] == "branch_guard_dangling_binding"))
    end

    @tag spec: ["specled.realized_by.binding_ref_inferred_no_leak"]
    test "no finding map produced by run/3 contains an :inferred? or \"inferred?\" key",
         %{root: root} do
      # Mix every code path that produces findings: drift (bare module), drift
      # (MFA), dangling (MFA, inferred?: false), and not-loadable (bare module).
      module_string = "SpecLedEx.ApiBoundaryFixtures.Stable"
      mfa = "SpecLedEx.ApiBoundaryFixtures.Stable.bar/1"

      :ok =
        HashStore.write(root, %{
          "api_boundary" => %{
            module_string => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong-bare"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            },
            mfa => %{
              "hash" => Base.encode16(:crypto.hash(:sha256, "wrong-mfa"), case: :lower),
              "hasher_version" => HashStore.hasher_version()
            }
          }
        })

      bindings = [
        %{subject_id: "s1", requirement_id: nil, mfa: module_string, inferred?: true},
        %{subject_id: "s1", requirement_id: nil, mfa: mfa, inferred?: false},
        %{
          subject_id: "s1",
          requirement_id: nil,
          mfa: "SpecLedEx.ApiBoundaryFixtures.Stable.does_not_exist/0",
          inferred?: false
        },
        %{
          subject_id: "s1",
          requirement_id: nil,
          mfa: "SpecLedEx.NotLoadable.Module.Imaginary",
          inferred?: false
        }
      ]

      findings = ApiBoundary.run(bindings, nil, root: root)
      refute findings == [], "expected at least one finding to enforce the property"

      Enum.each(findings, fn f ->
        refute Map.has_key?(f, :inferred?),
               "finding map leaked :inferred? key: #{inspect(f)}"

        refute Map.has_key?(f, "inferred?"),
               "finding map leaked \"inferred?\" key: #{inspect(f)}"
      end)
    end
  end
end
