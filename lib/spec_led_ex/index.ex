defmodule SpecLedEx.Index do
  @moduledoc false

  alias SpecLedEx.Parser

  def build(root, opts \\ []) do
    spec_dir = opts[:spec_dir] || detect_spec_dir(root)
    authored_dir = opts[:authored_dir] || detect_authored_dir(root, spec_dir)

    spec_files =
      root
      |> Path.join("#{authored_dir}/**/*.spec.md")
      |> Path.wildcard()
      |> Enum.sort()

    subjects = Enum.map(spec_files, &Parser.parse_file(&1, root))

    %{
      "version" => 1,
      "generated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "spec_dir" => spec_dir,
      "authored_dir" => authored_dir,
      "subjects" => subjects,
      "summary" => summary(subjects)
    }
  end

  def detect_spec_dir(root) do
    if File.dir?(Path.join(root, ".spec")) do
      ".spec"
    else
      raise ".spec directory not found in #{root}. Run mix spec.init."
    end
  end

  def detect_authored_dir(root, spec_dir) do
    authored = "#{spec_dir}/specs"

    if File.dir?(Path.join(root, authored)) do
      authored
    else
      raise "#{authored} directory not found in #{root}. Run mix spec.init."
    end
  end

  defp summary(subjects) do
    Enum.reduce(
      subjects,
      %{
        "subjects" => 0,
        "requirements" => 0,
        "scenarios" => 0,
        "verification_items" => 0,
        "exceptions" => 0,
        "parse_errors" => 0
      },
      fn subject, acc ->
        acc
        |> Map.update!("subjects", &(&1 + 1))
        |> Map.update!("requirements", &(&1 + length(subject["requirements"] || [])))
        |> Map.update!("scenarios", &(&1 + length(subject["scenarios"] || [])))
        |> Map.update!("verification_items", &(&1 + length(subject["verification"] || [])))
        |> Map.update!("exceptions", &(&1 + length(subject["exceptions"] || [])))
        |> Map.update!("parse_errors", &(&1 + length(subject["parse_errors"] || [])))
      end
    )
  end
end
