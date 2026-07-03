defmodule SpecLedEx.Review.FileDiffTest do
  # Binary/non-UTF-8 safety for the review diff surface.
  #
  # Regression for a CI-only crash in the first consumer of the shared
  # spec-check CI job: MIX_HOME/HEX_HOME caches restored into the workspace
  # left .hex/cache.ets (an :ets.tab2file dump) untracked in the repo root,
  # change_analysis picked it up via `ls-files --others --exclude-standard`,
  # and untracked_as_addition inlined its raw bytes into the diff lines —
  # UnicodeConversionError at HTML render time.
  use SpecLedEx.Case

  alias SpecLedEx.Review
  alias SpecLedEx.Review.FileDiff

  # Leading bytes of a real :ets.tab2file dump header (the shape Hex's
  # cache.ets carries): invalid as UTF-8 from the first byte.
  @ets_like_binary <<189, 98, 87, 76, 65, 131, 104, 18, 104, 2, 119, 2, 105, 100, 90, 0, 3>>

  describe "untracked non-UTF-8 files" do
    @tag spec: "specled.spec_review.binary_content_safe"
    test "render as a byte-size placeholder, never inlined bytes", %{root: root} do
      init_git_repo(root)
      write_files(root, %{"README.md" => "hello\n"})
      commit_all(root, "initial")

      binary_path = Path.join(root, ".hex/cache.ets")
      File.mkdir_p!(Path.dirname(binary_path))
      File.write!(binary_path, @ets_like_binary)

      diffs = FileDiff.for_files(root, "main", [".hex/cache.ets"])
      lines = Map.fetch!(diffs, ".hex/cache.ets")

      assert Enum.any?(lines, fn {kind, text} ->
               kind == :ctx and
                 text == "Binary file (#{byte_size(@ets_like_binary)} bytes) not shown"
             end)

      refute Enum.any?(lines, fn {kind, _text} -> kind == :add end)
      Enum.each(lines, fn {_kind, text} -> assert String.valid?(text) end)
    end

    @tag spec: "specled.spec_review.binary_content_safe"
    test "valid UTF-8 untracked files still render as full additions", %{root: root} do
      init_git_repo(root)
      write_files(root, %{"README.md" => "hello\n"})
      commit_all(root, "initial")
      write_files(root, %{"notes.txt" => "line one\nline two\n"})

      diffs = FileDiff.for_files(root, "main", ["notes.txt"])
      lines = Map.fetch!(diffs, "notes.txt")

      assert {:add, "+line one"} in lines
      assert {:add, "+line two"} in lines
    end
  end

  describe "tracked non-UTF-8 diffs" do
    @tag spec: "specled.spec_review.binary_content_safe"
    test "unified diff output is sanitized to valid UTF-8", %{root: root} do
      init_git_repo(root)
      # latin-1 e-acute (0xE9): git treats the file as text (no NUL bytes),
      # so the hunk body carries the raw invalid byte.
      write_files(root, %{"latin1.txt" => <<"caf", 0xE9, "\n">>})
      commit_all(root, "latin1 file")
      write_files(root, %{"latin1.txt" => <<"caf", 0xE9, " au lait\n">>})

      diffs = FileDiff.for_files(root, "HEAD", ["latin1.txt"])
      lines = Map.fetch!(diffs, "latin1.txt")

      assert lines != []
      Enum.each(lines, fn {_kind, text} -> assert String.valid?(text) end)
    end
  end

  describe "end-to-end artifact render" do
    @tag spec: "specled.spec_review.binary_content_safe"
    test "spec.review HTML renders when the change set contains an untracked binary", %{
      root: root
    } do
      init_git_repo(root)

      write_subject_spec(
        root,
        "auth_subject",
        meta: %{
          "id" => "auth.subject",
          "kind" => "module",
          "status" => "active",
          "summary" => "Auth subject.",
          "surface" => ["lib/auth.ex"]
        }
      )

      write_files(root, %{"lib/auth.ex" => "defmodule Auth do\nend\n"})
      commit_all(root, "initial")

      binary_path = Path.join(root, ".hex/cache.ets")
      File.mkdir_p!(Path.dirname(binary_path))
      File.write!(binary_path, @ets_like_binary)

      index = SpecLedEx.index(root)
      view = Review.build_view(index, root, base: "main")
      html = view |> Review.Html.render() |> IO.iodata_to_binary()

      assert html =~ "Binary file (#{byte_size(@ets_like_binary)} bytes) not shown"
    end
  end
end
