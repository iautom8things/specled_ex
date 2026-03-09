defmodule SpecLedEx do
  @moduledoc """
  Local tooling for Spec Led Development repositories.
  """

  alias SpecLedEx.{Index, Json, Verifier}

  @default_state ".spec/state.json"

  def build_index(root \\ File.cwd!(), opts \\ []) do
    Index.build(root, opts)
  end

  def verify(index, root \\ File.cwd!(), opts \\ []) do
    Verifier.verify(index, root, opts)
  end

  def read_state(root \\ File.cwd!(), output_path \\ @default_state) do
    path = Path.expand(output_path, root)
    Json.read(path)
  end

  def write_state(index, report, root \\ File.cwd!(), output_path \\ @default_state) do
    path = Path.expand(output_path, root)

    previous = read_state(root, output_path)

    state =
      previous
      |> Map.take(["verification"])
      |> Map.merge(%{
        "version" => 1,
        "updated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
        "spec_dir" => index["spec_dir"],
        "authored_dir" => index["authored_dir"],
        "index" => index
      })
      |> maybe_put_verification(report)

    Json.write!(path, state)
    path
  end

  def detect_spec_dir(root \\ File.cwd!()) do
    Index.detect_spec_dir(root)
  end

  def detect_authored_dir(root \\ File.cwd!(), spec_dir \\ nil) do
    Index.detect_authored_dir(root, spec_dir || detect_spec_dir(root))
  end

  defp maybe_put_verification(state, nil), do: state
  defp maybe_put_verification(state, report), do: Map.put(state, "verification", report)
end
