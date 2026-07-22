defmodule SpecLedEx.Evidence.StoreTest do
  use SpecLedEx.Case

  alias SpecLedEx.Evidence.{Entry, Store}

  @moduletag spec: [
               "specled.evidence_store.per_entry_isolation",
               "specled.evidence_store.run_stamp_wins",
               "specled.evidence_store.local_cas_bounded",
               "specled.evidence_store.self_create",
               "specled.evidence_store.local_only_write_path",
               "specled.evidence_store.attestation_never_gates"
             ]

  @tag spec: [
         "specled.evidence_store.per_entry_isolation",
         "specled.evidence_store.self_create",
         "specled.evidence_store.local_only_write_path"
       ]
  test "record self-creates the local orphan ref and stores one file per tree", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "root\n"})
    commit_all(root, "initial")

    first = entry(hash("1"), "2026-07-16T10:00:00.000000Z", String.duplicate("a", 32))
    second = entry(hash("2"), "2026-07-16T10:01:00.000000Z", String.duplicate("b", 32))

    assert :ok = Store.record(root, first)
    assert :ok = Store.record(root, second)

    files = evidence_files(root)

    assert Enum.sort(files) == Enum.sort(["#{hash("1")}.json", "#{hash("2")}.json"])
    assert {:ok, stored} = Store.read(root, hash("1"))
    assert stored["run_id"] == first["run_id"]
  end

  @tag spec: "specled.evidence_store.per_entry_isolation"
  test "read returns absent when the ref or entry does not exist", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "root\n"})
    commit_all(root, "initial")

    assert :absent = Store.read(root, hash("1"))
  end

  @tag spec: "specled.evidence_store.run_stamp_wins"
  test "same-key records keep the highest constructed run stamp", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "root\n"})
    commit_all(root, "initial")

    older = entry(hash("1"), "2026-07-16T10:00:00.000000Z", String.duplicate("a", 32))
    higher_tiebreaker = entry(hash("1"), "2026-07-16T10:00:00.000000Z", String.duplicate("b", 32))
    lower_run_at = entry(hash("1"), "2026-07-16T09:00:00.000000Z", String.duplicate("f", 32))

    assert :ok = Store.record(root, older)
    assert :ok = Store.record(root, higher_tiebreaker)
    assert {:ok, stored} = Store.read(root, hash("1"))
    assert stored["run_id"] == higher_tiebreaker["run_id"]

    assert :ok = Store.record(root, lower_run_at)
    assert {:ok, stored} = Store.read(root, hash("1"))
    assert stored["run_id"] == higher_tiebreaker["run_id"]
  end

  @tag spec: "specled.evidence_store.local_cas_bounded"
  test "CAS retry preserves a competing writer entry", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "root\n"})
    commit_all(root, "initial")

    first = entry(hash("1"), "2026-07-16T10:00:00.000000Z", String.duplicate("a", 32))
    competing = entry(hash("2"), "2026-07-16T10:00:01.000000Z", String.duplicate("b", 32))

    hook = fn
      hook_root, _entry, 1 ->
        Store.record(hook_root, competing)
        :ok

      _hook_root, _entry, _attempt ->
        :ok
    end

    assert :ok = Store.record(root, first, before_update: hook)

    assert Enum.sort(evidence_files(root)) ==
             Enum.sort(["#{hash("1")}.json", "#{hash("2")}.json"])
  end

  @tag spec: [
         "specled.evidence_store.local_cas_bounded",
         "specled.evidence_store.attestation_never_gates"
       ]
  test "CAS exhaustion returns a named warning instead of raising", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "root\n"})
    commit_all(root, "initial")

    first = entry(hash("1"), "2026-07-16T10:00:00.000000Z", String.duplicate("a", 32))

    hook = fn hook_root, _entry, attempt ->
      Store.record(
        hook_root,
        entry(
          hash(Integer.to_string(attempt + 1)),
          "2026-07-16T10:00:0#{attempt}.000000Z",
          String.duplicate("b", 32)
        )
      )

      :ok
    end

    assert {:warning, %{code: "evidence/local_write_failed", message: message}} =
             Store.record(root, first, before_update: hook)

    assert message =~ "cas_exhausted"
  end

  @tag spec: "specled.evidence_store.local_only_write_path"
  test "record removes the temporary index when a later git step fails", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "root\n"})
    commit_all(root, "initial")

    seeded = entry(hash("1"), "2026-07-16T10:00:00.000000Z", String.duplicate("a", 32))
    assert :ok = Store.record(root, seeded)

    objects_dir = Path.join(root, ".git/objects")
    lock_down(objects_dir)

    result =
      Store.record(
        root,
        entry(hash("2"), "2026-07-16T10:01:00.000000Z", String.duplicate("b", 32))
      )

    unlock(objects_dir)

    assert {:warning, %{code: "evidence/local_write_failed"}} = result
    assert File.ls!(Path.join(root, ".git/specled-tmp")) == []
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

  defp evidence_files(root) do
    root
    |> git!(["ls-tree", "--name-only", "refs/heads/spec-evidence"])
    |> String.split("\n", trim: true)
  end

  defp entry(tree_hash, run_at, run_id) do
    Entry.build(tree_hash, %{}, run_at: run_at, run_id: run_id, specled_version: "test")
  end

  defp hash(seed), do: String.duplicate(seed, 40)
end
