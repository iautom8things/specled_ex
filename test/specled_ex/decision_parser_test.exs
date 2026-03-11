defmodule SpecLedEx.DecisionParserTest do
  use SpecLedEx.Case

  alias SpecLedEx.DecisionParser

  test "parse_file extracts frontmatter, title, and required sections", %{root: root} do
    path =
      write_decision(
        root,
        "governance",
        """
        ---
        id: repo.governance.policy
        status: accepted
        date: 2026-03-11
        affects:
          - repo.governance
          - package.subject
        ---

        # Governance Policy

        ## Context

        Why the policy exists.

        ## Decision

        What the durable policy is.

        ## Consequences

        What changes because of it.
        """
      )

    decision = DecisionParser.parse_file(path, root)

    assert decision["file"] == ".spec/decisions/governance.md"
    assert decision["title"] == "Governance Policy"
    assert decision["meta"]["id"] == "repo.governance.policy"
    assert decision["meta"]["status"] == "accepted"
    assert decision["meta"]["affects"] == ["repo.governance", "package.subject"]
    assert decision["sections"] == ["Context", "Decision", "Consequences"]
    assert decision["parse_errors"] == []
  end

  test "parse_file records missing frontmatter as a parse error", %{root: root} do
    path =
      write_decision(
        root,
        "missing_frontmatter",
        """
        # Missing Frontmatter

        ## Context

        Missing metadata.
        """
      )

    decision = DecisionParser.parse_file(path, root)

    assert decision["meta"] == nil
    assert "decision frontmatter missing" in decision["parse_errors"]
  end
end
