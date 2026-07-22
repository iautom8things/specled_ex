defmodule SpecLedEx.Evidence.SyncTest do
  use SpecLedEx.Case, async: false

  alias SpecLedEx.Evidence.{Entry, Store, Sync}

  @ref "refs/heads/spec-evidence"

  @moduletag spec: [
               "specled.evidence_store.sync_tree_union",
               "specled.evidence_store.sync_failure_contracts",
               "specled.evidence_store.drift_surfaced",
               "specled.evidence_store.sync_entry_tolerance"
             ]

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "remote-absent pushes and local-absent adopts without checking out the evidence ref", %{
    root: fixture_root
  } do
    %{a: a, b: b} = sync_fixture(fixture_root, "absence")
    assert :ok = Store.record(a, entry(hash("1"), "10", "a"))

    assert {:ok, %{action: :pushed, ahead: 1, behind: 0}} =
             Sync.run(a, sleep: fn _ -> :ok end)

    assert ref_absent?(b, "refs/heads/spec-evidence")
    assert {:ok, %{action: :adopted, ahead: 0, behind: 1}} = Sync.run(b)
    assert evidence_ids(b) == [hash("1")]
    refute current_branch(a) == "spec-evidence"
    refute current_branch(b) == "spec-evidence"
  end

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "tree union converges in both push orders and higher same-key stamp wins", %{
    root: fixture_root
  } do
    for {name, order} <- [{"a-first", [:a, :b]}, {"b-first", [:b, :a]}] do
      fixture = sync_fixture(fixture_root, name)
      seed_divergent_entries(fixture)

      Enum.each(order, fn clone ->
        assert {:ok, _result} = Sync.run(Map.fetch!(fixture, clone), sleep: fn _ -> :ok end)
      end)

      assert {:ok, _result} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
      assert evidence_ids(fixture.a) == Enum.sort([hash("1"), hash("2"), hash("3")])
      assert {:ok, winner} = Store.read(fixture.a, hash("3"))
      assert winner["run_id"] == "b"

      assert length(
               String.split(
                 git!(fixture.a, ["show", "-s", "--format=%P", "refs/heads/spec-evidence"])
               )
             ) == 2

      refute current_branch(fixture.a) == "spec-evidence"
      refute current_branch(fixture.b) == "spec-evidence"
    end
  end

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "lease rejection refetches, re-merges, and succeeds", %{root: fixture_root} do
    fixture = sync_fixture(fixture_root, "retry")
    assert :ok = Store.record(fixture.b, entry(hash("2"), "20", "b"))
    assert {:ok, _} = Sync.run(fixture.b)
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))

    before_push = fn _root, attempt, _fetched ->
      if attempt == 1 do
        assert :ok = Store.record(fixture.b, entry(hash("3"), "30", "c"))
        git!(fixture.b, ["push", "origin", "refs/heads/spec-evidence:refs/heads/spec-evidence"])
      end

      :ok
    end

    assert {:ok, %{attempts: 2}} =
             Sync.run(fixture.a, before_push: before_push, sleep: fn _ -> :ok end)

    assert evidence_ids(fixture.a) == Enum.sort([hash("1"), hash("2"), hash("3")])
  end

  @tag spec: "specled.evidence_store.sync_failure_contracts"
  test "three consecutive lease rejections exhaust the bounded retry", %{root: fixture_root} do
    fixture = sync_fixture(fixture_root, "exhaust")
    assert :ok = Store.record(fixture.b, entry(hash("2"), "20", "seed"))
    assert {:ok, _} = Sync.run(fixture.b)
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))

    before_push = fn _root, attempt, _fetched ->
      assert {:ok, _} = Sync.run(fixture.b, sleep: fn _ -> :ok end)

      assert :ok =
               Store.record(
                 fixture.b,
                 entry(hash(Integer.to_string(attempt + 3)), "3#{attempt}", "race")
               )

      git!(fixture.b, ["push", "origin", "refs/heads/spec-evidence:refs/heads/spec-evidence"])
      :ok
    end

    assert {:error, {:sync_exhausted, _reason}} =
             Sync.run(fixture.a, before_push: before_push, sleep: fn _ -> :ok end)
  end

  @tag spec: "specled.evidence_store.sync_entry_tolerance"
  test "quarantines an invalid path, unparsable JSON, and a future schema version without halting",
       %{root: fixture_root} do
    fixture = sync_fixture(fixture_root, "quarantine")
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))

    bad_path = "notes.txt"
    bad_path_content = "not an evidence entry\n"
    garbage_filename = "#{hash("9")}.json"
    garbage_content = "{not json"
    future_filename = "#{hash("8")}.json"

    future_content =
      Jason.encode!(%{
        "schema_version" => 2,
        "tree_hash" => hash("8"),
        "run_at" => "20",
        "run_id" => "future-peer"
      })

    inject_raw_entry(fixture.a, bad_path, bad_path_content)
    inject_raw_entry(fixture.a, garbage_filename, garbage_content)
    inject_raw_entry(fixture.a, future_filename, future_content)

    assert {:ok, result} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
    assert result.action == :pushed
    assert length(result.warnings) == 3
    assert Enum.all?(result.warnings, &(&1.code == "evidence/entry_quarantined"))
    assert Enum.any?(result.warnings, &String.contains?(&1.message, bad_path))
    assert Enum.any?(result.warnings, &String.contains?(&1.message, garbage_filename))
    assert Enum.any?(result.warnings, &String.contains?(&1.message, future_filename))

    assert hash("1") in evidence_ids(fixture.a)

    for {root, path, content} <- [
          {fixture.a, bad_path, bad_path_content},
          {fixture.a, garbage_filename, garbage_content},
          {fixture.a, future_filename, future_content}
        ] do
      assert git!(root, ["cat-file", "-p", "refs/heads/spec-evidence:#{path}"]) == content
    end

    assert {:ok, adopted} = Sync.run(fixture.b, sleep: fn _ -> :ok end)
    assert adopted.action == :adopted

    for {path, content} <- [
          {bad_path, bad_path_content},
          {garbage_filename, garbage_content},
          {future_filename, future_content}
        ] do
      assert git!(fixture.b, ["cat-file", "-p", "refs/heads/spec-evidence:#{path}"]) == content
    end
  end

  @tag spec: "specled.evidence_store.sync_entry_tolerance"
  test "quarantined entries independently written at the same path converge deterministically", %{
    root: fixture_root
  } do
    fixture = sync_fixture(fixture_root, "quarantine-conflict")
    path = "#{hash("9")}.json"
    from_a = "{garbage from a"
    from_b = "{garbage from b, a longer payload"

    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))
    inject_raw_entry(fixture.a, path, from_a)

    assert :ok = Store.record(fixture.b, entry(hash("2"), "10", "b"))
    inject_raw_entry(fixture.b, path, from_b)

    assert {:ok, _} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
    assert {:ok, _} = Sync.run(fixture.b, sleep: fn _ -> :ok end)
    assert {:ok, _} = Sync.run(fixture.a, sleep: fn _ -> :ok end)

    winner = Enum.max([from_a, from_b])
    assert git!(fixture.a, ["cat-file", "-p", "refs/heads/spec-evidence:#{path}"]) == winner
    assert git!(fixture.b, ["cat-file", "-p", "refs/heads/spec-evidence:#{path}"]) == winner
    assert evidence_ids(fixture.a) == Enum.sort([hash("1"), hash("2"), hash("9")])
  end

  defp inject_raw_entry(root, filename, content) do
    index_path = Path.join(System.tmp_dir!(), "raw-index-#{System.unique_integer([:positive])}")
    blob_path = Path.join(System.tmp_dir!(), "raw-blob-#{System.unique_integer([:positive])}")
    File.write!(blob_path, content)

    parent =
      case System.cmd("git", ["-C", root, "rev-parse", "--verify", "--quiet", @ref], []) do
        {output, 0} -> String.trim(output)
        _ -> nil
      end

    env = [{"GIT_INDEX_FILE", index_path}]

    if parent do
      raw_git!(root, ["read-tree", "#{parent}^{tree}"], env)
    end

    blob = raw_git!(root, ["hash-object", "-w", blob_path], env) |> String.trim()
    raw_git!(root, ["update-index", "--add", "--cacheinfo", "100644,#{blob},#{filename}"], env)
    tree = raw_git!(root, ["write-tree"], env) |> String.trim()

    commit_args =
      if parent do
        ["commit-tree", tree, "-p", parent, "-m", "inject raw entry"]
      else
        ["commit-tree", tree, "-m", "inject raw entry"]
      end

    commit = raw_git!(root, commit_args, env) |> String.trim()
    old = parent || String.duplicate("0", 40)
    raw_git!(root, ["update-ref", @ref, commit, old], [])

    File.rm(blob_path)
    File.rm(index_path)
    commit
  end

  defp raw_git!(root, args, env) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp seed_divergent_entries(fixture) do
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))
    assert :ok = Store.record(fixture.a, entry(hash("3"), "20", "a"))
    assert :ok = Store.record(fixture.b, entry(hash("2"), "10", "b"))
    assert :ok = Store.record(fixture.b, entry(hash("3"), "20", "b"))
  end

  defp sync_fixture(root, name) do
    origin = Path.join(root, "#{name}-origin.git")
    seed = Path.join(root, "#{name}-seed")
    git!(root, ["init", "--bare", origin])
    File.mkdir_p!(seed)
    init_git_repo(seed)
    write_files(seed, %{"README.md" => "fixture\n"})
    commit_all(seed, "initial")
    git!(seed, ["remote", "add", "origin", origin])
    git!(seed, ["push", "-u", "origin", "main"])

    %{
      origin: origin,
      a: clone!(origin, Path.join(root, "#{name}-a")),
      b: clone!(origin, Path.join(root, "#{name}-b"))
    }
  end

  defp clone!(origin, path) do
    git!(Path.dirname(path), ["clone", origin, path])
    git!(path, ["config", "user.name", "Spec Led Test"])
    git!(path, ["config", "user.email", "specled@example.com"])
    path
  end

  defp evidence_ids(root) do
    root
    |> git!(["ls-tree", "--name-only", "refs/heads/spec-evidence"])
    |> String.split("\n", trim: true)
    |> Enum.map(&Path.rootname(&1, ".json"))
    |> Enum.sort()
  end

  defp current_branch(root), do: root |> git!(["branch", "--show-current"]) |> String.trim()

  defp ref_absent?(root, ref) do
    {_output, status} = System.cmd("git", ["-C", root, "rev-parse", "--verify", "--quiet", ref])
    status != 0
  end

  defp entry(tree_hash, run_at, run_id) do
    Entry.build(tree_hash, %{}, run_at: run_at, run_id: run_id, specled_version: "test")
  end

  defp hash(seed), do: seed |> String.pad_trailing(40, seed) |> binary_part(0, 40)
end
