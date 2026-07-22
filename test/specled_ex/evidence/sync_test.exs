defmodule SpecLedEx.Evidence.SyncTest do
  use SpecLedEx.Case, async: false

  import SpecLedEx.EvidenceHelpers

  alias SpecLedEx.Evidence.{Entry, Store, Sync}

  @ref "refs/heads/spec-evidence"

  @moduletag spec: [
               "specled.evidence_store.sync_tree_union",
               "specled.evidence_store.sync_failure_contracts",
               "specled.evidence_store.drift_surfaced",
               "specled.evidence_store.sync_entry_tolerance",
               "specled.evidence_store.sync_tree_level_tolerance",
               "specled.evidence_store.sync_noop_short_circuit",
               "specled.evidence_store.sync_auto_prune",
               "specled.evidence_store.prune_reachability_floor",
               "specled.evidence_store.sync_bounded_subprocesses"
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

  @tag spec: "specled.evidence_store.sync_noop_short_circuit"
  test "a no-op sync (local and remote already equal) never re-reads an entry, even a quarantined one",
       %{root: fixture_root} do
    fixture = sync_fixture(fixture_root, "noop-shortcut")
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))
    inject_raw_entry(fixture.a, "notes.txt", "not an evidence entry\n")

    assert {:ok, pushed} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
    assert pushed.action == :pushed
    assert length(pushed.warnings) == 1

    assert {:ok, noop} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
    assert noop.action == :noop
    assert noop.ahead == 0
    assert noop.behind == 0
    assert noop.warnings == []
  end

  @tag spec: "specled.evidence_store.sync_auto_prune"
  test "a real reconciliation folds the reachable-set keep-set in once the merged entry count crosses the threshold",
       %{root: fixture_root} do
    fixture = sync_fixture(fixture_root, "auto-prune-over")
    reachable = fixture.a |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    unreachable = String.duplicate("f", 40)

    assert :ok = Store.record(fixture.a, entry(reachable, "10", "a"))
    assert :ok = Store.record(fixture.a, entry(unreachable, "20", "b"))

    assert {:ok, result} =
             Sync.run(fixture.a, auto_prune_threshold: 1, sleep: fn _ -> :ok end)

    assert result.action == :pushed
    assert evidence_ids(fixture.a) == [reachable]
  end

  @tag spec: "specled.evidence_store.sync_auto_prune"
  test "a real reconciliation below the threshold leaves unreachable entries for explicit spec.prune",
       %{
         root: fixture_root
       } do
    fixture = sync_fixture(fixture_root, "auto-prune-under")
    reachable = fixture.a |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    unreachable = String.duplicate("e", 40)

    assert :ok = Store.record(fixture.a, entry(reachable, "10", "a"))
    assert :ok = Store.record(fixture.a, entry(unreachable, "20", "b"))

    assert {:ok, result} =
             Sync.run(fixture.a, auto_prune_threshold: 10, sleep: fn _ -> :ok end)

    assert result.action == :pushed
    assert evidence_ids(fixture.a) == Enum.sort([reachable, unreachable])
  end

  @tag spec: [
         "specled.evidence_store.sync_auto_prune",
         "specled.evidence_store.prune_reachability_floor"
       ]
  test "auto-prune degrades to an unpruned sync with a warning when the keep-set is empty", %{
    root: fixture_root
  } do
    fixture = sync_fixture(fixture_root, "auto-prune-floor")
    reachable = fixture.a |> git!(["rev-parse", "HEAD^{tree}"]) |> String.trim()
    unreachable = String.duplicate("d", 40)

    assert :ok = Store.record(fixture.a, entry(reachable, "10", "a"))
    assert :ok = Store.record(fixture.a, entry(unreachable, "20", "b"))

    drop_non_evidence_refs(fixture.a)

    assert {:ok, result} =
             Sync.run(fixture.a, auto_prune_threshold: 1, sleep: fn _ -> :ok end)

    assert result.action == :pushed
    assert [warning] = result.warnings
    assert warning.code == "evidence/auto_prune_degraded"
    assert evidence_ids(fixture.a) == Enum.sort([reachable, unreachable])
  end

  @tag spec: "specled.evidence_store.sync_tree_union"
  test "the ledger push bypasses pre-push hooks so a sync-invoking hook cannot recurse", %{
    root: fixture_root
  } do
    fixture = sync_fixture(fixture_root, "hook-bypass")

    hook_path = Path.join(fixture.a, ".git/hooks/pre-push")
    File.mkdir_p!(Path.dirname(hook_path))
    File.write!(hook_path, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook_path, 0o755)

    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))

    assert {:ok, %{action: :pushed}} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
    assert git!(fixture.a, ["ls-remote", "origin", "refs/heads/spec-evidence"]) != ""
  end

  @tag spec: [
         "specled.evidence_store.sync_auto_prune",
         "specled.evidence_store.prune_reachability_floor"
       ]
  test "auto-prune degrades instead of wiping when the keep-set matches no stored entry", %{
    root: fixture_root
  } do
    fixture = sync_fixture(fixture_root, "auto-prune-disjoint")
    unreachable_one = String.duplicate("a", 40)
    unreachable_two = String.duplicate("b", 40)

    assert :ok = Store.record(fixture.a, entry(unreachable_one, "10", "a"))
    assert :ok = Store.record(fixture.a, entry(unreachable_two, "20", "b"))

    assert {:ok, result} =
             Sync.run(fixture.a, auto_prune_threshold: 1, sleep: fn _ -> :ok end)

    assert result.action == :pushed
    assert [warning] = result.warnings
    assert warning.code == "evidence/auto_prune_degraded"
    assert warning.message =~ "keep_set_would_wipe_store"
    assert evidence_ids(fixture.a) == Enum.sort([unreachable_one, unreachable_two])
  end

  @tag spec: "specled.evidence_store.sync_tree_level_tolerance"
  test "a crafted non-blob tree entry is carried through opaquely instead of halting", %{
    root: fixture_root
  } do
    fixture = sync_fixture(fixture_root, "gitlink")
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))

    gitlink_oid = fixture.a |> git!(["rev-parse", "HEAD"]) |> String.trim()
    inject_crafted_tree_entry(fixture.a, "160000 commit #{gitlink_oid}\tvendored")

    assert {:ok, result} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
    assert result.action == :pushed
    assert [warning] = result.warnings
    assert warning.code == "evidence/entry_quarantined"
    assert warning.message =~ "vendored"

    assert git!(fixture.a, ["ls-tree", @ref]) =~ "160000 commit #{gitlink_oid}\tvendored"

    assert {:ok, adopted} = Sync.run(fixture.b, sleep: fn _ -> :ok end)
    assert adopted.action == :adopted
    assert git!(fixture.b, ["ls-tree", @ref]) =~ "160000 commit #{gitlink_oid}\tvendored"
  end

  @tag spec: "specled.evidence_store.sync_tree_level_tolerance"
  test "an entry at a git-rejectable path is dropped from the union with a warning", %{
    root: fixture_root
  } do
    fixture = sync_fixture(fixture_root, "unstageable-path")
    assert :ok = Store.record(fixture.a, entry(hash("1"), "10", "a"))

    blob_oid =
      fixture.a |> git!(["rev-parse", "#{@ref}:#{hash("1")}.json"]) |> String.trim()

    inject_crafted_tree_entry(fixture.a, "100644 blob #{blob_oid}\t.git")

    assert {:ok, result} = Sync.run(fixture.a, sleep: fn _ -> :ok end)
    assert result.action == :pushed
    assert [warning] = result.warnings
    assert warning.code == "evidence/entry_skipped"
    assert warning.message =~ ".git"

    listing = git!(fixture.a, ["ls-tree", "--name-only", @ref])
    refute listing =~ ~r/^\.git$/m
    assert hash("1") in evidence_ids(fixture.a)
  end

  @tag spec: [
         "specled.evidence_store.sync_tree_union",
         "specled.evidence_store.sync_bounded_subprocesses"
       ]
  test "a reconcile crossing the write-chunk boundary preserves every path-content mapping", %{
    root: fixture_root
  } do
    fixture = sync_fixture(fixture_root, "chunk-boundary")
    entries = seed_bulk_entries(fixture.a, 205)

    assert {:ok, result} =
             Sync.run(fixture.a, auto_prune_threshold: 1_000, sleep: fn _ -> :ok end)

    assert result.action == :pushed
    assert result.warnings == []

    assert evidence_ids(fixture.a) ==
             entries |> Enum.map(fn {tree_hash, _} -> tree_hash end) |> Enum.sort()

    for {tree_hash, content} <- entries do
      assert git!(fixture.a, ["cat-file", "-p", "#{@ref}:#{tree_hash}.json"]) == content
    end
  end

  @tag spec: "specled.evidence_store.sync_bounded_subprocesses"
  test "reconcile git subprocess count stays bounded independent of entry count", %{
    root: fixture_root
  } do
    fixture = sync_fixture(fixture_root, "spawn-bound")
    seed_bulk_entries(fixture.a, 205)

    task =
      Task.async(fn ->
        receive do
          :go -> Sync.run(fixture.a, auto_prune_threshold: 1_000, sleep: fn _ -> :ok end)
        end
      end)

    :erlang.trace(task.pid, true, [:call])
    :erlang.trace_pattern({SpecLedEx.Evidence.Git, :run, 3}, true, [:local])
    send(task.pid, :go)

    assert {:ok, %{action: :pushed}} = Task.await(task, 120_000)

    :erlang.trace_pattern({SpecLedEx.Evidence.Git, :run, 3}, false, [:local])
    spawn_count = drain_trace_calls()

    assert spawn_count <= 25,
           "expected a bounded reconcile, got #{spawn_count} Git.run calls for 205 entries"
  end

  defp drain_trace_calls(count \\ 0) do
    receive do
      {:trace, _pid, :call, {SpecLedEx.Evidence.Git, :run, _args}} -> drain_trace_calls(count + 1)
    after
      0 -> count
    end
  end

  # Seeds `count` valid entries directly into the local evidence ref with a
  # handful of test-side git calls (temp files -> one hash-object -w -> one
  # mktree), so bulk fixtures do not pay `count` full Store.record round
  # trips. Returns the seeded [{tree_hash, encoded_json}] list.
  defp seed_bulk_entries(root, count) do
    entries =
      for n <- 1..count do
        tree_hash =
          :crypto.hash(:sha, "bulk-#{n}") |> Base.encode16(case: :lower)

        encoded =
          tree_hash
          |> Entry.build(%{},
            run_at: "2026-07-16T10:00:00.#{String.pad_leading("#{n}", 6, "0")}Z",
            run_id: String.pad_leading("#{n}", 32, "0"),
            specled_version: "test"
          )
          |> Entry.encode!()

        {tree_hash, encoded}
      end

    dir = Path.join(root, "bulk-entries")
    File.mkdir_p!(dir)

    files =
      Enum.map(entries, fn {tree_hash, encoded} ->
        file = Path.join(dir, tree_hash)
        File.write!(file, encoded)
        file
      end)

    oids =
      root
      |> git!(["hash-object", "-w", "--" | files])
      |> String.split("\n", trim: true)

    mktree_input =
      entries
      |> Enum.zip(oids)
      |> Enum.map_join("", fn {{tree_hash, _}, oid} ->
        "100644 blob #{oid}\t#{tree_hash}.json\n"
      end)

    write_crafted_tree(root, mktree_input, nil)
    File.rm_rf!(dir)
    entries
  end

  # Appends one raw `ls-tree`-format line to the current evidence tree via
  # `git mktree` — the plumbing a hostile contributor could use, since
  # `update-index` refuses these entries.
  defp inject_crafted_tree_entry(root, mktree_line) do
    parent =
      case System.cmd("git", ["-C", root, "rev-parse", "--verify", "--quiet", @ref], []) do
        {output, 0} -> String.trim(output)
        _ -> nil
      end

    existing = if parent, do: git!(root, ["ls-tree", @ref]), else: ""
    write_crafted_tree(root, existing <> mktree_line <> "\n", parent)
  end

  defp write_crafted_tree(root, mktree_input, parent) do
    parent =
      parent ||
        case System.cmd("git", ["-C", root, "rev-parse", "--verify", "--quiet", @ref], []) do
          {output, 0} -> String.trim(output)
          _ -> nil
        end

    input_path = Path.join(root, "mktree-input")
    File.write!(input_path, mktree_input)

    {tree, 0} =
      System.cmd("sh", ["-c", ~s(git -C "$1" mktree < "$2"), "sh", root, input_path],
        stderr_to_stdout: true
      )

    File.rm!(input_path)
    tree = String.trim(tree)

    commit_args =
      if parent do
        ["commit-tree", tree, "-p", parent, "-m", "crafted evidence tree"]
      else
        ["commit-tree", tree, "-m", "crafted evidence tree"]
      end

    commit = root |> git!(commit_args) |> String.trim()
    old = parent || String.duplicate("0", 40)
    git!(root, ["update-ref", @ref, commit, old])
    commit
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
    git!(root, ["init", "--bare", "-b", "main", origin])
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
