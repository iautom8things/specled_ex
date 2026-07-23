defmodule Mix.Tasks.SpecCheckAcceptDriftTest do
  # specled_-uv3: `mix spec.check --accept-drift` accepts intentional realization
  # drift into the committed baseline in a single run — even in a repo that pins
  # the drift code to `:error` (as specled_ex itself does) — so the drift does
  # not resurface once the branch merges and the `Spec-Drift:` trailer window
  # closes. Kept in its own file (tagged only for `specled.tasks`) so it does not
  # pull the broad `spec_tasks_test.exs` moduletag onto the change.
  use SpecLedEx.Case

  alias SpecLedEx.Realization.HashStore

  @moduletag spec: ["specled.tasks.accept_drift_flag"]

  test "spec.check --accept-drift refreshes the baseline over a drift=error config pin",
       %{root: root} do
    init_git_repo(root)
    mfa = "SpecLedEx.Coverage.default_artifact_path/0"
    wrong = Base.encode16(:crypto.hash(:sha256, "wrong"), case: :lower)

    write_files(root, %{
      ".spec/config.yml" => """
      branch_guard:
        severities:
          branch_guard_realization_drift: error
      """
    })

    write_subject_spec(root, "accept_task",
      meta: %{
        "id" => "accept_task.subject",
        "kind" => "module",
        "status" => "active",
        "realized_by" => %{"api_boundary" => [mfa]}
      }
    )

    commit_all(root, "seed accept_task subject")

    # Manufacture drift: committed hash disagrees with current.
    :ok =
      HashStore.write(root, %{
        "api_boundary" => %{
          mfa => %{"hash" => wrong, "hasher_version" => HashStore.hasher_version()}
        }
      })

    # Without the flag, the drift=error pin fails the run and the baseline is
    # NOT refreshed (drift blocks the refresh).
    assert_raise Mix.Error, ~r/Spec check failed/, fn ->
      Mix.Tasks.Spec.Check.run(["--root", root, "--base", "HEAD", "--no-run-commands"])
    end

    assert get_in(HashStore.read(root), ["api_boundary", mfa, "hash"]) == wrong

    reenable_tasks()
    drain_shell_messages()

    # With --accept-drift the run passes (the injected trailer override beats the
    # config pin) and the committed hash is refreshed to the current value.
    Mix.Tasks.Spec.Check.run([
      "--root",
      root,
      "--base",
      "HEAD",
      "--no-run-commands",
      "--accept-drift"
    ])

    refreshed = get_in(HashStore.read(root), ["api_boundary", mfa, "hash"])
    refute refreshed == wrong, "expected --accept-drift to refresh the committed hash"
  end
end
