defmodule SpecLedEx.FindingMessage do
  @moduledoc """
  Canonical producer for governance-finding message bodies.

  `finalize/2` is the single source of truth for the "<prose>\\n\\n```\\nfix:
  ...\\n```" shape emitted by the append-only, overlap, and branch-check
  detectors. `SpecLedEx.Review.HTML.split_fix_block/1` regex-parses that exact
  shape, so any change here must stay in lockstep with that parser.
  """

  @doc """
  Combine a prose `body` and a `fix_line` into the canonical finding message.

  Trailing whitespace on `body` is trimmed; `fix_line` is placed verbatim
  inside a bare (unlabeled) fenced code block. The result has no trailing
  newline.
  """
  @spec finalize(String.t(), String.t()) :: String.t()
  def finalize(body, fix_line) do
    """
    #{String.trim_trailing(body)}

    ```
    #{fix_line}
    ```\
    """
  end
end
