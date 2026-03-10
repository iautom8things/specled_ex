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

    subjects = index["subjects"] || []

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    normalized_index = normalize_index(subjects)
    findings = if report, do: report["findings"] || [], else: []

    summary =
      (index["summary"] || %{})
      |> Map.merge(%{
        "findings" => length(findings),
        "verifications" => (index["summary"] || %{})["verification_items"] || 0
      })
      |> Map.delete("verification_items")
      |> Map.delete("parse_errors")

    state = %{
      "specification_version" => "1.0",
      "generated_at" => now,
      "workspace" => %{
        "root" => root,
        "spec_count" => length(subjects)
      },
      "index" => normalized_index,
      "findings" => normalize_findings(findings),
      "summary" => summary
    }

    Json.write!(path, state)
    path
  end

  def detect_spec_dir(root \\ File.cwd!()) do
    Index.detect_spec_dir(root)
  end

  def detect_authored_dir(root \\ File.cwd!(), spec_dir \\ nil) do
    Index.detect_authored_dir(root, spec_dir || detect_spec_dir(root))
  end

  defp normalize_index(subjects) do
    requirements =
      Enum.flat_map(subjects, fn s ->
        file = s["file"]
        subject_id = (s["meta"] || %{})["id"]
        Enum.map(s["requirements"] || [], &Map.merge(&1, %{"file" => file, "subject_id" => subject_id}))
      end)

    scenarios =
      Enum.flat_map(subjects, fn s ->
        file = s["file"]
        subject_id = (s["meta"] || %{})["id"]
        Enum.map(s["scenarios"] || [], &Map.merge(&1, %{"file" => file, "subject_id" => subject_id}))
      end)

    verifications =
      Enum.flat_map(subjects, fn s ->
        file = s["file"]
        subject_id = (s["meta"] || %{})["id"]
        Enum.map(s["verification"] || [], &Map.merge(&1, %{"file" => file, "subject_id" => subject_id}))
      end)

    exceptions =
      Enum.flat_map(subjects, fn s ->
        file = s["file"]
        subject_id = (s["meta"] || %{})["id"]
        Enum.map(s["exceptions"] || [], &Map.merge(&1, %{"file" => file, "subject_id" => subject_id}))
      end)

    %{
      "subjects" => Enum.map(subjects, fn s ->
        %{
          "id" => (s["meta"] || %{})["id"],
          "file" => s["file"],
          "title" => s["title"],
          "meta" => s["meta"]
        }
      end),
      "requirements" => requirements,
      "scenarios" => scenarios,
      "verifications" => verifications,
      "exceptions" => exceptions
    }
  end

  defp normalize_findings(findings) do
    Enum.map(findings, fn f ->
      %{
        "code" => f["code"],
        "level" => f["severity"] || f["level"],
        "message" => f["message"]
      }
      |> maybe_put("file", f["file"])
      |> maybe_put("entity_id", f["subject_id"])
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
