defmodule SpecLedEx.Evidence.GitTest do
  use SpecLedEx.Case

  alias SpecLedEx.Evidence.Git

  @moduletag spec: [
               "specled.evidence_store.sync_tree_union",
               "specled.evidence_store.sync_bounded_subprocesses"
             ]

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "cat_file_batch returns blob contents in request order through one subprocess", %{
    root: root
  } do
    init_git_repo(root)
    write_files(root, %{"README.md" => "fixture\n"})
    commit_all(root, "initial")

    contents = for n <- 1..50, do: "entry #{n} " <> String.duplicate("x", n)

    blobs =
      Enum.map(contents, fn content ->
        blob_path = Path.join(root, "blob.tmp")
        File.write!(blob_path, content)
        blob = root |> git!(["hash-object", "-w", blob_path]) |> String.trim()
        File.rm!(blob_path)
        blob
      end)

    assert {:ok, read} = Git.cat_file_batch(root, blobs)
    assert read == contents

    shuffled = Enum.reverse(blobs)
    assert {:ok, reversed} = Git.cat_file_batch(root, shuffled)
    assert reversed == Enum.reverse(contents)
  end

  @tag spec: [
         "specled.evidence_store.sync_tree_union",
         "specled.evidence_store.sync_bounded_subprocesses"
       ]
  test "cat_file_batch round-trips newline-bearing, header-lookalike, empty, and large blobs",
       %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "fixture\n"})
    commit_all(root, "initial")

    contents = [
      "",
      "line1\nline2\n\nline4\n",
      "#{String.duplicate("a", 40)} blob 12\nnot-a-header\n",
      Base.encode64(:crypto.strong_rand_bytes(200_000)),
      "tail entry"
    ]

    blobs =
      Enum.map(contents, fn content ->
        blob_path = Path.join(root, "blob.tmp")
        File.write!(blob_path, content)
        blob = root |> git!(["hash-object", "-w", blob_path]) |> String.trim()
        File.rm!(blob_path)
        blob
      end)

    assert {:ok, read} = Git.cat_file_batch(root, blobs)
    assert read == contents
  end

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "cat_file_batch is empty-safe and fails whole-call on a missing object", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "fixture\n"})
    commit_all(root, "initial")

    assert {:ok, []} = Git.cat_file_batch(root, [])

    blob = root |> git!(["hash-object", "-w", Path.join(root, "README.md")]) |> String.trim()
    absent = String.duplicate("d", 40)

    assert {:error, {:missing_object, ^absent}} = Git.cat_file_batch(root, [blob, absent])
  end
end
