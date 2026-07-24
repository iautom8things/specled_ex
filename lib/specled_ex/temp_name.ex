defmodule SpecLedEx.TempName do
  @moduledoc """
  Cross-VM collision-proof suffixes for temp file and directory names.

  `System.unique_integer/1` is unique only within one BEAM VM. Nested or
  parallel specled runs share `System.tmp_dir!/0`, so a VM-local counter lets
  one run's cleanup delete or truncate another run's in-flight temp file —
  an exit-127 blamed on an innocent subject for command scripts, or a
  stolen/truncated attribution artifact (mass `cover_not_executed` on a
  completed run) for the streaming sidecar. The OS pid separates
  concurrently live VMs; the random suffix covers pid reuse against stale
  same-name leftovers.
  """

  @doc "Returns a `<os-pid>_<12-hex-chars>` suffix safe across concurrent VMs."
  @spec cross_vm_suffix() :: String.t()
  def cross_vm_suffix do
    "#{System.pid()}_#{Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)}"
  end
end
