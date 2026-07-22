defmodule SpecLedEx.Evidence.EntryTest do
  use SpecLedEx.Case

  alias SpecLedEx.Evidence.Entry

  @tree String.duplicate("a", 40)

  @moduletag spec: [
               "specled.evidence_store.per_entry_isolation",
               "specled.evidence_store.run_stamp_wins"
             ]

  @tag spec: "specled.evidence_store.per_entry_isolation"
  test "builds canonical JSON with verification outcomes and normalized findings" do
    report = %{
      "verification" => %{
        "claims" => [
          %{
            "cover_id" => "subject.req",
            "strength" => "executed",
            "meets_minimum" => true
          }
        ]
      },
      "findings" => [
        %{
          "code" => "example",
          "severity" => "warning",
          "message" => "Example warning",
          "subject_id" => "subject",
          "file" => ".spec/specs/subject.spec.md"
        }
      ]
    }

    entry =
      Entry.build(@tree, report,
        run_at: "2026-07-16T10:00:00.000000Z",
        run_id: String.duplicate("b", 32),
        specled_version: "test"
      )

    encoded = Entry.encode!(entry)

    assert encoded == Entry.encode!(Jason.decode!(encoded))
    assert {:ok, decoded} = Entry.decode_file("#{@tree}.json", encoded)
    assert decoded["schema_version"] == 1
    assert decoded["tree_hash"] == @tree

    assert decoded["verification"]["subject.req"] == %{
             "strength" => "executed",
             "meets_minimum" => true
           }

    assert decoded["findings"] == [
             %{
               "code" => "example",
               "entity_id" => "subject",
               "file" => ".spec/specs/subject.spec.md",
               "level" => "warning",
               "message" => "Example warning"
             }
           ]
  end

  @tag spec: "specled.evidence_store.per_entry_isolation"
  test "validates entry filenames on read" do
    entry =
      Entry.build(@tree, %{},
        run_at: "2026-07-16T10:00:00.000000Z",
        run_id: String.duplicate("a", 32)
      )

    assert {:error, :invalid_filename} = Entry.decode_file("../bad.json", Entry.encode!(entry))

    assert {:error, :tree_hash_mismatch} =
             Entry.decode_file("#{String.duplicate("b", 40)}.json", Entry.encode!(entry))
  end

  @tag spec: "specled.evidence_store.per_entry_isolation"
  test "distinguishes malformed JSON and unsupported schema versions from other decode failures" do
    filename = "#{@tree}.json"

    assert {:error, {:malformed_json, _reason}} = Entry.decode_file(filename, "{not json")

    future =
      Jason.encode!(%{
        "schema_version" => 2,
        "tree_hash" => @tree,
        "run_at" => "x",
        "run_id" => "y"
      })

    assert {:error, {:unsupported_schema_version, 2}} = Entry.decode_file(filename, future)

    missing_version = Jason.encode!(%{"tree_hash" => @tree, "run_at" => "x", "run_id" => "y"})

    assert {:error, :missing_schema_version} = Entry.decode_file(filename, missing_version)
  end

  @tag spec: "specled.evidence_store.run_stamp_wins"
  test "latest keeps the lexicographically highest run stamp" do
    older = entry("2026-07-16T10:00:00.000000Z", String.duplicate("a", 32))
    higher_tiebreaker = entry("2026-07-16T10:00:00.000000Z", String.duplicate("b", 32))
    lower_run_at = entry("2026-07-16T09:00:00.000000Z", String.duplicate("f", 32))

    assert Entry.latest(older, higher_tiebreaker)["run_id"] == higher_tiebreaker["run_id"]
    assert Entry.latest(higher_tiebreaker, lower_run_at)["run_id"] == higher_tiebreaker["run_id"]
  end

  defp entry(run_at, run_id), do: Entry.build(@tree, %{}, run_at: run_at, run_id: run_id)
end
