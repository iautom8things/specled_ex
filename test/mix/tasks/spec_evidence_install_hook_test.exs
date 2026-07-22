defmodule Mix.Tasks.Spec.Evidence.InstallHookTest do
  use SpecLedEx.Case

  @moduletag spec: [
               "specled.evidence_store.hook_static_never_blocks",
               "specled.tasks.evidence_install_hook"
             ]

  test "installs a static pre-push shim that exits 0 when sync fails", %{root: root} do
    init_git_repo(root)

    Mix.Tasks.Spec.Evidence.InstallHook.run(["--root", root])

    hook_path = Path.join(root, ".git/hooks/pre-push")
    shim = File.read!(hook_path)

    assert shim == Mix.Tasks.Spec.Evidence.InstallHook.shim_bytes()
    refute shim =~ root
    assert shim =~ "mix spec.sync --best-effort"

    {_output, 0} = System.cmd(hook_path, [], cd: root, stderr_to_stdout: true)
  end

  test "refuses to overwrite an existing pre-push hook and prints append snippet", %{root: root} do
    init_git_repo(root)
    hook_path = Path.join(root, ".git/hooks/pre-push")
    original = "#!/bin/sh\necho user hook\n"
    File.write!(hook_path, original)

    Mix.Tasks.Spec.Evidence.InstallHook.run(["--root", root])

    assert File.read!(hook_path) == original

    messages = drain_shell_messages()
    assert message_contains?(messages, "pre-push hook already exists")
    assert message_contains?(messages, "mix spec.sync --best-effort")
  end
end
