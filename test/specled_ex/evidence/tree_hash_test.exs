defmodule SpecLedEx.Evidence.TreeHashTest do
  use SpecLedEx.Case

  alias SpecLedEx.Evidence.TreeHash

  @moduletag spec: ["specled.evidence_store.tree_hash_mirrors_add_all"]

  @tag spec: "specled.evidence_store.tree_hash_mirrors_add_all"
  test "current tree mirrors git add -A with untracked, deleted, and ignored files", %{root: root} do
    init_git_repo(root)

    write_files(root, %{
      ".gitignore" => "ignored.txt\n",
      "tracked.txt" => "before\n",
      "deleted.txt" => "delete me\n"
    })

    commit_all(root, "initial")

    write_files(root, %{
      "tracked.txt" => "after\n",
      "new.txt" => "new\n",
      "ignored.txt" => "ignored one\n"
    })

    File.rm!(Path.join(root, "deleted.txt"))

    assert {:ok, first_hash} = TreeHash.current(root)

    write_files(root, %{"ignored.txt" => "ignored two\n"})

    assert {:ok, ^first_hash} = TreeHash.current(root)

    commit_all(root, "same state")

    assert String.trim(git!(root, ["rev-parse", "HEAD^{tree}"])) == first_hash
  end

  @tag spec: "specled.evidence_store.tree_hash_mirrors_add_all"
  test "base resolves a ref tree using end-of-options hardened rev-parse", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"tracked.txt" => "content\n"})
    commit_all(root, "initial")

    assert {:ok, tree_hash} = TreeHash.base(root, "HEAD")
    assert tree_hash == String.trim(git!(root, ["rev-parse", "HEAD^{tree}"]))
  end

  @tag spec: "specled.evidence_store.tree_hash_mirrors_add_all"
  test "current removes the temporary index when a later git step fails", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"tracked.txt" => "before\n"})
    commit_all(root, "initial")
    write_files(root, %{"tracked.txt" => "after\n"})

    objects_dir = Path.join(root, ".git/objects")
    lock_down(objects_dir)

    result = TreeHash.current(root)

    unlock(objects_dir)

    assert {:error, {:git, ["add", "-A"], _output, _status}} = result

    tmp_dir = Path.join(root, ".git/specled-tmp")
    assert File.ls!(tmp_dir) == []
  end

  defp lock_down(objects_dir) do
    for entry <- File.ls!(objects_dir), File.dir?(Path.join(objects_dir, entry)) do
      File.chmod!(Path.join(objects_dir, entry), 0o500)
    end

    File.chmod!(objects_dir, 0o500)
  end

  defp unlock(objects_dir) do
    File.chmod!(objects_dir, 0o700)

    for entry <- File.ls!(objects_dir), File.dir?(Path.join(objects_dir, entry)) do
      File.chmod!(Path.join(objects_dir, entry), 0o700)
    end
  end
end
