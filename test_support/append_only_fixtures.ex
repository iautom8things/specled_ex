defmodule SpecLedEx.AppendOnlyFixtures do
  @moduledoc """
  State-shaped payload builders for `SpecLedEx.AppendOnly` tests.

  The builders emit string-keyed maps matching the canonical shape written
  by `SpecLedEx.normalize_for_state/1`. They compose without Git I/O or
  fixture files on disk — every append-only scenario is driven entirely
  through these functions.

  ## Core

      iex> state = state_fixture(
      ...>   subject: "payments",
      ...>   requirements: [requirement("payments.req_a", "The system MUST reject invalid input.")],
      ...>   scenarios: [scenario(id: "payments.scenario.a", covers: ["payments.req_a"])]
      ...> )
      iex> state["index"]["requirements"] |> length()
      1

  Call `adr/1` to produce a decision entry — either as a member of
  `state_fixture/1`'s `:decisions` option (it lands in
  `state["decisions"]["items"]`) or as a member of the separate head-side
  `decisions` list passed to `AppendOnly.analyze/4` (where it carries the
  full `"meta"` shape that DecisionParser produces).
  """

  @doc """
  Builds a requirement map with the fields AppendOnly reads.

  Accepts keyword options: `:subject_id`, `:file`, `:priority`, `:stability`,
  `:polarity`. Defaults match the shape produced by `normalize_for_state/1`.
  """
  def requirement(id, statement, opts \\ []) when is_binary(id) and is_binary(statement) do
    subject_id = Keyword.get(opts, :subject_id, subject_id_of(id))

    %{
      "id" => id,
      "subject_id" => subject_id,
      "file" => Keyword.get(opts, :file, ".spec/specs/#{subject_id}.spec.md"),
      "statement" => statement,
      "priority" => Keyword.get(opts, :priority, "must"),
      "stability" => Keyword.get(opts, :stability, "evolving")
    }
    |> maybe_put("polarity", Keyword.get(opts, :polarity))
  end

  @doc """
  Builds a scenario map.

  Required option: `:covers` (list of requirement ids). Optional: `:id`,
  `:subject_id`, `:file`, `:given`, `:when`, `:then`, `:execute`, `:reason`.
  """
  def scenario(opts) when is_list(opts) do
    covers = Keyword.fetch!(opts, :covers)
    subject_id = Keyword.get(opts, :subject_id, default_subject_from_covers(covers))
    id = Keyword.get(opts, :id, "#{subject_id}.scenario.#{:erlang.unique_integer([:positive])}")

    base = %{
      "id" => id,
      "subject_id" => subject_id,
      "file" => Keyword.get(opts, :file, ".spec/specs/#{subject_id}.spec.md"),
      "covers" => covers
    }

    base
    |> maybe_put("given", Keyword.get(opts, :given))
    |> maybe_put("when", Keyword.get(opts, :when))
    |> maybe_put("then", Keyword.get(opts, :then))
    |> maybe_put("execute", Keyword.get(opts, :execute))
    |> maybe_put("reason", Keyword.get(opts, :reason))
  end

  @doc """
  Builds a decision/ADR map.

  The output has two shapes depending on `:form`:

  * `:state` (default) — flat map suitable for `state["decisions"]["items"]`.
    Carries `id`, `file`, `title`, `status`, `date`, `affects`, and (when set)
    `change_type`, `reverses_what`, `replaces`, `superseded_by`.

  * `:parsed` — shape matching `DecisionParser.parse_file/2`. Has a nested
    `"meta"` map carrying the frontmatter fields. This is what the
    head-side `decisions` list argument to `AppendOnly.analyze/4` looks like
    in production.

  Required option: `:id`. Optional: `:status`, `:date`, `:affects`,
  `:change_type`, `:reverses_what`, `:replaces`, `:title`, `:file`,
  `:superseded_by`, `:form`.
  """
  def adr(opts) when is_list(opts) do
    id = Keyword.fetch!(opts, :id)
    form = Keyword.get(opts, :form, :state)
    status = Keyword.get(opts, :status, "accepted")
    date = Keyword.get(opts, :date, "2026-04-23")
    affects = Keyword.get(opts, :affects, [])
    change_type = Keyword.get(opts, :change_type)
    reverses_what = Keyword.get(opts, :reverses_what)
    replaces = Keyword.get(opts, :replaces)
    title = Keyword.get(opts, :title, "ADR #{id}")
    file = Keyword.get(opts, :file, ".spec/decisions/#{id}.md")
    superseded_by = Keyword.get(opts, :superseded_by)

    case form do
      :state ->
        %{
          "id" => id,
          "file" => file,
          "title" => title,
          "status" => status,
          "date" => date,
          "affects" => affects
        }
        |> maybe_put("change_type", change_type)
        |> maybe_put("reverses_what", reverses_what)
        |> maybe_put("replaces", replaces)
        |> maybe_put("superseded_by", superseded_by)

      :parsed ->
        meta =
          %{
            "id" => id,
            "status" => status,
            "date" => date,
            "affects" => affects
          }
          |> maybe_put("change_type", change_type)
          |> maybe_put("reverses_what", reverses_what)
          |> maybe_put("replaces", replaces)
          |> maybe_put("superseded_by", superseded_by)

        %{
          "file" => file,
          "title" => title,
          "meta" => meta,
          "sections" => [],
          "parse_errors" => []
        }
    end
  end

  @doc """
  Builds a full state-shaped payload.

  Accepts keyword options:

    * `:subject` — subject id for the default surface; defaults to `"x"`.
    * `:subjects` — explicit list of subject maps. When given, replaces the
      synthesized default subject.
    * `:requirements` — list of requirement maps (`requirement/3`).
    * `:scenarios` — list of scenario maps (`scenario/1`).
    * `:decisions` — list of ADR maps (`adr/1` with `form: :state`).

  The returned map is string-keyed and flat-indexed: `requirements`,
  `scenarios`, `verifications`, `exceptions`, `subjects` all live under
  `state["index"]`. `decisions` live under `state["decisions"]["items"]`.
  """
  def state_fixture(opts \\ []) when is_list(opts) do
    subject_id = Keyword.get(opts, :subject, "x")

    subjects =
      case Keyword.get(opts, :subjects) do
        nil -> [default_subject(subject_id)]
        list -> list
      end

    requirements = Keyword.get(opts, :requirements, [])
    scenarios = Keyword.get(opts, :scenarios, [])
    decisions = Keyword.get(opts, :decisions, [])
    verifications = Keyword.get(opts, :verifications, [])
    exceptions = Keyword.get(opts, :exceptions, [])

    %{
      "specification_version" => "1.0",
      "workspace" => %{
        "spec_count" => length(subjects),
        "decision_count" => length(decisions)
      },
      "index" => %{
        "subjects" => subjects,
        "requirements" => requirements,
        "scenarios" => scenarios,
        "verifications" => verifications,
        "exceptions" => exceptions
      },
      "decisions" => %{
        "items" => decisions
      },
      "findings" => [],
      "summary" => %{
        "subjects" => length(subjects),
        "requirements" => length(requirements),
        "scenarios" => length(scenarios),
        "decisions" => length(decisions),
        "findings" => 0,
        "verifications" => length(verifications)
      }
    }
  end

  defp default_subject(subject_id) do
    %{
      "id" => subject_id,
      "file" => ".spec/specs/#{subject_id}.spec.md",
      "title" => String.capitalize(subject_id),
      "meta" => %{
        "id" => subject_id,
        "kind" => "module",
        "status" => "active"
      }
    }
  end

  defp subject_id_of(id) when is_binary(id) do
    case String.split(id, ".") do
      [head, _ | _] -> head
      [only] -> only
    end
  end

  defp default_subject_from_covers([first | _]), do: subject_id_of(first)
  defp default_subject_from_covers(_), do: "x"

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
