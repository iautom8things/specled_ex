defmodule SpecLedEx.EvidenceHelpers do
  @moduledoc """
  Shared git-plumbing helpers for evidence-store tests.

  These helpers reify the subtlest contracts on the evidence ledger —
  quarantine carry-through, the prune reachability floor, and temp-file
  hygiene — so they live in exactly one place instead of drifting apart as
  per-file copies.
  """

  @ref "refs/heads/spec-evidence"

  @doc """
  Sorted tree hashes (filename rootnames) currently stored on the local
  evidence ref.
  """
  def evidence_ids(root) do
    root
    |> raw_git!(["ls-tree", "--name-only", @ref])
    |> String.split("\n", trim: true)
    |> Enum.map(&Path.rootname(&1, ".json"))
    |> Enum.sort()
  end

  @doc """
  Writes one raw blob into the evidence tree under `filename` with plumbing
  only — the shape a peer (or attacker) could produce without going through
  `Store.record/3`. Returns the new evidence commit.
  """
  def inject_raw_entry(root, filename, content) do
    index_path = Path.join(System.tmp_dir!(), "raw-index-#{System.unique_integer([:positive])}")
    blob_path = Path.join(System.tmp_dir!(), "raw-blob-#{System.unique_integer([:positive])}")
    File.write!(blob_path, content)

    parent = evidence_commit(root)
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
    raw_git!(root, ["update-ref", @ref, commit, old])

    File.rm(blob_path)
    File.rm(index_path)
    commit
  end

  @doc """
  Deletes every non-evidence branch and remote-tracking ref, leaving a
  checkout whose reachable keep-set computes empty — the reachability-floor
  trigger.
  """
  def drop_non_evidence_refs(repo) do
    System.cmd(
      "git",
      ["-C", repo, "symbolic-ref", "--delete", "refs/remotes/origin/HEAD"],
      stderr_to_stdout: true
    )

    repo
    |> raw_git!(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"])
    |> String.split("\n", trim: true)
    |> Enum.reject(&String.ends_with?(&1, "/spec-evidence"))
    |> Enum.each(&raw_git!(repo, ["update-ref", "-d", &1]))
  end

  @doc """
  Makes `.git/objects` read-only so the next object write fails — the
  standard failure injection for temp-index cleanup tests. Pair with
  `unlock/1`.
  """
  def lock_down(objects_dir) do
    for entry <- File.ls!(objects_dir), File.dir?(Path.join(objects_dir, entry)) do
      File.chmod!(Path.join(objects_dir, entry), 0o500)
    end

    File.chmod!(objects_dir, 0o500)
  end

  @doc "Reverses `lock_down/1`."
  def unlock(objects_dir) do
    File.chmod!(objects_dir, 0o700)

    for entry <- File.ls!(objects_dir), File.dir?(Path.join(objects_dir, entry)) do
      File.chmod!(Path.join(objects_dir, entry), 0o700)
    end
  end

  @doc """
  Runs git with an optional extra environment, raising on non-zero exit.
  """
  def raw_git!(root, args, env \\ []) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true, env: env) do
      {output, 0} -> output
      {output, status} -> raise "git #{Enum.join(args, " ")} failed (#{status}): #{output}"
    end
  end

  defp evidence_commit(root) do
    case System.cmd("git", ["-C", root, "rev-parse", "--verify", "--quiet", @ref], []) do
      {output, 0} -> String.trim(output)
      _ -> nil
    end
  end
end
