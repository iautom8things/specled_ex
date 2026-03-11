defmodule SpecLedEx.IndexStateTest do
  use SpecLedEx.Case

  alias SpecLedEx.Index

  test "build_index summarizes authored specs and detects directories", %{root: root} do
    write_files(root, %{
      ".spec/specs/alpha.spec.md" => """
      # Alpha

      ```spec-meta
      id: alpha.subject
      kind: module
      status: active
      ```

      ```spec-requirements
      - id: alpha.requirement
        statement: Alpha requirement
      ```

      ```spec-scenarios
      - id: alpha.scenario
        covers:
          - alpha.requirement
        given:
          - alpha given
        when:
          - alpha when
        then:
          - alpha then
      ```
      """,
      ".spec/specs/beta.spec.md" => """
      # Beta

      ```spec-meta
      id: beta.subject
      kind: module
      status: active
      ```

      ```spec-verification
      - kind: source_file
        target: README.md
        covers:
          - alpha.requirement
      ```

      ```spec-exceptions
      - id: beta.exception
        covers:
          - alpha.requirement
        reason: documented waiver
      ```
      """
    })

    assert SpecLedEx.detect_spec_dir(root) == ".spec"
    assert SpecLedEx.detect_authored_dir(root) == ".spec/specs"
    assert Index.detect_spec_dir(root) == ".spec"
    assert Index.detect_authored_dir(root, ".spec") == ".spec/specs"

    index = SpecLedEx.build_index(root)

    assert index["summary"] == %{
             "subjects" => 2,
             "requirements" => 1,
             "scenarios" => 1,
             "verification_items" => 1,
             "exceptions" => 1,
             "parse_errors" => 0
           }
  end

  test "detect_spec_dir and detect_authored_dir raise when directories are missing", %{root: root} do
    assert_raise RuntimeError, ~r/\.spec directory not found/, fn ->
      SpecLedEx.detect_spec_dir(root)
    end

    File.mkdir_p!(Path.join(root, ".spec"))

    assert_raise RuntimeError, ~r/\.spec\/specs directory not found/, fn ->
      SpecLedEx.detect_authored_dir(root)
    end
  end

  test "build_index supports absolute spec_dir paths", %{root: root} do
    abs_spec_dir = Path.join(root, "custom_spec")

    write_files(root, %{
      "custom_spec/specs/absolute.spec.md" => """
      # Absolute

      ```spec-meta
      id: absolute.subject
      kind: module
      status: active
      ```
      """
    })

    assert Index.detect_authored_dir(root, abs_spec_dir) == Path.join(abs_spec_dir, "specs")

    index = SpecLedEx.build_index(root, spec_dir: abs_spec_dir)

    assert index["spec_dir"] == abs_spec_dir
    assert index["authored_dir"] == Path.join(abs_spec_dir, "specs")
    assert index["summary"]["subjects"] == 1
  end

  test "write_state skips malformed items and normalizes findings", %{root: root} do
    write_spec(
      root,
      "malformed",
      """
      # Malformed

      ```spec-meta
      id: malformed.subject
      kind: module
      status: active
      ```

      ```spec-requirements
      - just-a-string
      ```
      """
    )

    index = SpecLedEx.build_index(root)

    report = %{
      "findings" => [
        %{
          "code" => "parse_error",
          "severity" => "warning",
          "message" => "Malformed item",
          "file" => ".spec/specs/malformed.spec.md",
          "subject_id" => "malformed.subject"
        },
        %{
          "code" => "custom_level",
          "level" => "error",
          "message" => "Already normalized"
        },
        "not-a-finding"
      ]
    }

    path = SpecLedEx.write_state(index, report, root)
    state = read_state(root)

    assert path == Path.join(root, ".spec/state.json")
    assert state["index"]["requirements"] == []
    assert state["summary"]["requirements"] == 1
    assert state["summary"]["findings"] == 3
    refute Map.has_key?(state, "generated_at")
    refute Map.has_key?(state["workspace"], "root")

    assert state["findings"] == [
             %{
               "code" => "custom_level",
               "level" => "error",
               "message" => "Already normalized"
             },
             %{
               "code" => "parse_error",
               "entity_id" => "malformed.subject",
               "file" => ".spec/specs/malformed.spec.md",
               "level" => "warning",
               "message" => "Malformed item"
             }
           ]
  end

  test "write_state sorts normalized data and persists verification summary", %{root: root} do
    index = %{
      "subjects" => [
        state_subject("zeta.subject", ".spec/specs/zeta.spec.md",
          title: "Zeta",
          requirements: [%{"id" => "zeta.requirement", "statement" => "Zeta"}],
          verification: [
            %{"kind" => "source_file", "target" => "lib/zeta.ex", "covers" => ["zeta.requirement"]},
            %{"kind" => "source_file", "target" => "lib/zeta_2.ex", "covers" => ["zeta.requirement"]}
          ]
        ),
        state_subject("alpha.subject", ".spec/specs/alpha.spec.md",
          title: "Alpha",
          requirements: [%{"id" => "alpha.requirement", "statement" => "Alpha"}],
          verification: [
            %{"kind" => "source_file", "target" => "lib/alpha.ex", "covers" => ["alpha.requirement"]}
          ]
        )
      ],
      "summary" => index_summary(subjects: 2, requirements: 2, verification_items: 3)
    }

    report = %{
      "findings" => [
        report_finding("zeta_warning",
          severity: "warning",
          message: "Second finding",
          file: ".spec/specs/zeta.spec.md",
          subject_id: "zeta.subject"
        ),
        report_finding("alpha_error",
          severity: "error",
          message: "First finding",
          file: ".spec/specs/alpha.spec.md",
          subject_id: "alpha.subject"
        )
      ],
      "verification" => %{
        "default_minimum_strength" => "claimed",
        "cli_minimum_strength" => "linked",
        "strength_summary" => %{"executed" => 0, "linked" => 1, "claimed" => 2},
        "threshold_failures" => 2,
        "claims" => [
          verification_claim("zeta.requirement",
            subject_id: "zeta.subject",
            file: ".spec/specs/zeta.spec.md",
            verification_index: 1,
            target: "lib/zeta_2.ex",
            strength: "claimed",
            required_strength: "linked",
            meets_minimum: false
          ),
          verification_claim("alpha.requirement",
            subject_id: "alpha.subject",
            file: ".spec/specs/alpha.spec.md",
            verification_index: 0,
            target: "lib/alpha.ex",
            strength: "linked",
            required_strength: "linked",
            meets_minimum: true
          )
        ]
      }
    }

    SpecLedEx.write_state(index, report, root)
    state = read_state(root)

    assert Enum.map(state["index"]["subjects"], & &1["id"]) == ["alpha.subject", "zeta.subject"]
    assert Enum.map(state["index"]["verifications"], & &1["target"]) == [
             "lib/alpha.ex",
             "lib/zeta.ex",
             "lib/zeta_2.ex"
           ]
    assert Enum.map(state["findings"], & &1["code"]) == ["alpha_error", "zeta_warning"]
    assert state["verification"]["cli_minimum_strength"] == "linked"
    assert Enum.map(state["verification"]["claims"], & &1["cover_id"]) == [
             "alpha.requirement",
             "zeta.requirement"
           ]
  end

  test "read_state supports custom output paths", %{root: root} do
    index = %{
      "subjects" => [],
      "summary" => %{
        "subjects" => 0,
        "requirements" => 0,
        "scenarios" => 0,
        "verification_items" => 0,
        "exceptions" => 0,
        "parse_errors" => 0
      }
    }

    SpecLedEx.write_state(index, nil, root, "tmp/custom_state.json")

    assert SpecLedEx.read_state(root, "tmp/custom_state.json")["workspace"]["spec_count"] == 0
  end

  defp state_subject(id, file, opts) do
    %{
      "file" => file,
      "title" => Keyword.get(opts, :title),
      "meta" => %{"id" => id, "kind" => "module", "status" => "active"},
      "requirements" => Keyword.get(opts, :requirements, []),
      "scenarios" => Keyword.get(opts, :scenarios, []),
      "verification" => Keyword.get(opts, :verification, []),
      "exceptions" => Keyword.get(opts, :exceptions, []),
      "parse_errors" => Keyword.get(opts, :parse_errors, [])
    }
  end

  defp index_summary(opts) do
    %{
      "subjects" => Keyword.get(opts, :subjects, 0),
      "requirements" => Keyword.get(opts, :requirements, 0),
      "scenarios" => Keyword.get(opts, :scenarios, 0),
      "verification_items" => Keyword.get(opts, :verification_items, 0),
      "exceptions" => Keyword.get(opts, :exceptions, 0),
      "parse_errors" => Keyword.get(opts, :parse_errors, 0)
    }
  end

  defp report_finding(code, opts) do
    %{
      "code" => code,
      "severity" => Keyword.fetch!(opts, :severity),
      "message" => Keyword.fetch!(opts, :message),
      "file" => Keyword.get(opts, :file),
      "subject_id" => Keyword.get(opts, :subject_id)
    }
  end

  defp verification_claim(cover_id, opts) do
    %{
      "subject_id" => Keyword.fetch!(opts, :subject_id),
      "file" => Keyword.fetch!(opts, :file),
      "verification_index" => Keyword.fetch!(opts, :verification_index),
      "kind" => "source_file",
      "target" => Keyword.fetch!(opts, :target),
      "cover_id" => cover_id,
      "strength" => Keyword.fetch!(opts, :strength),
      "required_strength" => Keyword.fetch!(opts, :required_strength),
      "meets_minimum" => Keyword.fetch!(opts, :meets_minimum)
    }
  end
end
