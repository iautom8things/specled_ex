defmodule SpecLedEx.TempName do
  @moduledoc """
  Cross-VM collision-proof suffixes for temp file and directory names.

  `System.unique_integer/1` is unique only within one BEAM VM. Nested or
  parallel specled runs share tmp locations, so a VM-local counter lets one
  run's cleanup delete, truncate, overwrite, or misparse another run's
  in-flight temp file: command scripts, streaming attribution artifacts,
  review/base-view/spec-diff parse inputs, command-output captures, and
  write-rename siblings all need the same cross-VM uniqueness story.

  The OS pid separates concurrently live VMs; the random suffix covers pid
  reuse against stale same-name leftovers.
  """

  @doc "Returns a `<os-pid>_<12-hex-chars>` suffix safe across concurrent VMs."
  @spec cross_vm_suffix() :: String.t()
  def cross_vm_suffix do
    "#{System.pid()}_#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
  end
end
