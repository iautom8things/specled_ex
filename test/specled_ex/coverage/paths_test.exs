defmodule SpecLedEx.Coverage.PathsTest do
  use ExUnit.Case, async: true

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
  end
end
