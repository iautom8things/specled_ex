defmodule Mix.Tasks.SpecSyncTaskTest do
  use SpecLedEx.Case, async: false

  alias SpecLedEx.Evidence.{Entry, Store}

  @ref "refs/heads/spec-evidence"

  @moduletag spec: [
               "specled.evidence_store.sync_tree_union",
               "specled.evidence_store.sync_failure_contracts",
               "specled.evidence_store.drift_surfaced",
               "specled.evidence_store.sync_entry_tolerance",
               "specled.tasks.sync_evidence"
             ]

  setup do
    Mix.Task.reenable("spec.sync")
    :ok
  end

  @tag spec: ["specled.evidence_store.sync_tree_union", "specled.evidence_store.drift_surfaced"]
  test "task drives the production Sync.run/2 path through a real bare-origin push", %{root: root} do
    repo = remote_repo!(root)

    entry =
      Entry.build(String.duplicate("a", 40), %{},
        run_at: "10",
        run_id: "a",
        specled_version: "test"
      )

    assert :ok = Store.record(repo, entry)

    assert :ok = Mix.Tasks.Spec.Sync.run(["--root", repo])
    messages = drain_shell_messages()

    assert message_contains?(messages, "spec-evidence drift as of last fetch: ahead=1 behind=0")
    assert git!(repo, ["ls-remote", "origin", "refs/heads/spec-evidence"]) != ""
  end

  @tag spec: "specled.evidence_store.sync_failure_contracts"
  test "default raises while best-effort emits exactly one warning and returns ok", %{root: root} do
    init_git_repo(root)
    write_files(root, %{"README.md" => "fixture\n"})
    commit_all(root, "initial")

    assert_raise Mix.Error, ~r/evidence\/sync_failed/, fn ->
      Mix.Tasks.Spec.Sync.run(["--root", root])
    end

    Mix.Task.reenable("spec.sync")
    Mix.Shell.Process.flush()
    assert :ok = Mix.Tasks.Spec.Sync.run(["--root", root, "--best-effort"])

    warnings = drain_shell_messages() |> Enum.filter(&String.contains?(&1, "warning:"))
    assert length(warnings) == 1
    assert hd(warnings) =~ "evidence/sync_failed"
  end

  @tag spec: ["specled.tasks.sync_evidence", "specled.evidence_store.sync_entry_tolerance"]
  test "task surfaces a quarantine warning without raising or changing exit status", %{
    root: root
  } do
    repo = remote_repo!(root)
    inject_raw_entry(repo, "notes.txt", "not an evidence entry\n")

    assert :ok = Mix.Tasks.Spec.Sync.run(["--root", repo])
    messages = drain_shell_messages()

    assert message_contains?(messages, "spec-evidence drift as of last fetch")
    assert message_contains?(messages, "evidence/entry_quarantined")
    assert message_contains?(messages, "notes.txt")
  end

  defp remote_repo!(root) do
    origin = Path.join(root, "origin.git")
    repo = Path.join(root, "repo")
    git!(root, ["init", "--bare", origin])
    File.mkdir_p!(repo)
    init_git_repo(repo)
    write_files(repo, %{"README.md" => "fixture\n"})
    commit_all(repo, "initial")
    git!(repo, ["remote", "add", "origin", origin])
    git!(repo, ["push", "-u", "origin", "main"])
    repo
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
end
