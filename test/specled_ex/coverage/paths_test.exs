defmodule SpecLedEx.Coverage.PathsTest do
  # load?-discrimination mutates the code path and purges an ephemeral
  # fixture module; keep serial so concurrent suites never observe a half
  # torn-down beam path.
  use ExUnit.Case, async: false

  alias SpecLedEx.Coverage.Paths

  describe "to_binary/1" do
    test "converts a charlist to a binary" do
      assert Paths.to_binary(~c"lib/foo.ex") == "lib/foo.ex"
    end

    test "returns a binary unchanged" do
      assert Paths.to_binary("lib/foo.ex") == "lib/foo.ex"
    end
  end

  describe "repo_relative/1 and repo_relative_list/1" do
    test "absolute in-repo path becomes repo-relative" do
      root = File.cwd!() |> Path.expand()
      absolute = Path.join(root, "lib/specled_ex/coverage/paths.ex")

      assert Paths.repo_relative(absolute) == "lib/specled_ex/coverage/paths.ex"
      assert Paths.repo_relative_list(absolute) == ["lib/specled_ex/coverage/paths.ex"]
    end

    test "out-of-repo absolute path yields nil / empty list" do
      outside = "/tmp/not-in-this-repo/source.ex"

      assert Paths.repo_relative(outside) == nil
      assert Paths.repo_relative_list(outside) == []
    end

    test "already-relative in-repo path is unchanged" do
      relative = "lib/specled_ex/coverage/paths.ex"

      assert Paths.repo_relative(relative) == relative
      assert Paths.repo_relative_list(relative) == [relative]
    end

    test "non-binary input yields nil / empty list" do
      assert Paths.repo_relative(:not_a_path) == nil
      assert Paths.repo_relative(nil) == nil
      assert Paths.repo_relative_list(:not_a_path) == []
      assert Paths.repo_relative_list(nil) == []
    end
  end

  describe "module_source/2" do
    test "loaded in-repo module resolves under both load? modes" do
      # Paths itself is already loaded and compiled from this repo.
      expected = "lib/specled_ex/coverage/paths.ex"

      assert Paths.module_source(Paths, false) == expected
      assert Paths.module_source(Paths, true) == expected

      assert Paths.repo_relative_list(Paths.module_source(Paths, true)) == [expected]
    end

    test "unloadable module yields nil under both load? modes (and [] via list wrap)" do
      nonexistent = Module.concat([SpecLedEx, Coverage, Paths, __MODULE__, Unloadable])

      refute Code.ensure_loaded?(nonexistent)
      assert :code.is_loaded(nonexistent) == false

      assert Paths.module_source(nonexistent, false) == nil
      assert Paths.module_source(nonexistent, true) == nil
      assert Paths.repo_relative_list(Paths.module_source(nonexistent, true)) == []
    end

    test "loadable-but-not-loaded module discriminates load?: false from load?: true" do
      # The only input that can split the two ensure_module/2 clauses: a
      # module that is on the code path but not currently loaded.
      #
      # Build an ephemeral beam outside Mix.Project.compile_path() so cover
      # never compiled it and purging cannot de-instrument a tracked lib/
      # module. Beam directory and recorded :source are independent: put
      # the beam in a throwaway dir, but compile with an in-repo :file so
      # Paths.repo_relative/1 still resolves (the path need not exist).
      # Do not define the module inline in this .exs (no beam => after purge
      # ensure_loaded returns :nofile and both load? modes agree on nil).
      # Do not place a fixture under test/test_support/ (same ebin cover walks).
      # Do not purge a dependency module (dep sources / out-of-checkout break).
      uid = :erlang.unique_integer([:positive])
      mod = Module.concat([SpecLedEx, Coverage, PathsTest, Ephemeral, :"M#{uid}"])
      # In-repo path recorded as compile :source — nothing reads the file.
      expected = "lib/specled_ex/coverage/paths_test_ephemeral.ex"

      tmp_dir =
        Path.join(System.tmp_dir!(), "specled_paths_ephemeral_#{uid}")

      File.mkdir_p!(tmp_dir)

      source = """
      defmodule #{inspect(mod)} do
        def ping, do: :ok
      end
      """

      [{^mod, bytecode}] = Code.compile_string(source, expected)
      File.write!(Path.join(tmp_dir, "#{mod}.beam"), bytecode)
      true = :code.add_patha(String.to_charlist(tmp_dir))

      # compile_string left the module loaded; purge so it is loadable-but-unloaded.
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)

      on_exit(fn ->
        :code.purge(mod)
        :code.delete(mod)
        :code.purge(mod)
        :code.del_path(String.to_charlist(tmp_dir))
        File.rm_rf!(tmp_dir)
      end)

      refute match?({_kind, _path}, :code.is_loaded(mod))

      # load?: false must not force-load (coverage collection posture).
      assert Paths.module_source(mod, false) == nil
      # Still not loaded after the non-forcing probe.
      refute match?({_kind, _path}, :code.is_loaded(mod))

      # load?: true may force-load (closure / triangle posture).
      assert Paths.module_source(mod, true) == expected

      # Would fail if ensure_module/2 collapsed to a single clause that
      # ignores load? in either direction: always-:code.is_loaded would
      # make load?: true also return nil; always-Code.ensure_loaded would
      # make load?: false also return the path.
    end
  end
end
