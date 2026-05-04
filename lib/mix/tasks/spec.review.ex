defmodule Mix.Tasks.Spec.Review do
  use Mix.Task

  @requirements ["app.config"]

  @shortdoc "Renders a spec-aware PR review HTML artifact for the current change set"

  # covers: specled.tasks.review_html_artifact
  # covers: specled.spec_review.diff_against_base
  # covers: specled.spec_review.same_artifact_local_and_ci

  @moduledoc """
  Builds a self-contained HTML artifact rendering the current Git change
  set as a spec-aware PR review surface.

  ## Options

    * `--base` — explicit base ref. Defaults to the same auto-detection
      as `mix spec.next` (origin/main, main, master, HEAD).
    * `--output` — output file path. Defaults to `_build/spec_review.html`.
    * `--root` — repo root. Defaults to the current working directory.
    * `--open` — open the rendered file in the default browser when running
      locally. No-op in CI / when `open`/`xdg-open` are unavailable.

  The same code path produces the same artifact locally and in CI. The
  HTML embeds all CSS and JavaScript inline; no network resources are
  fetched at view time.
  """

  @impl Mix.Task
  def run(args) do
    SpecLedEx.MixRuntime.ensure_started!()

    {opts, rest, invalid} =
      OptionParser.parse(
        args,
        strict: [
          root: :string,
          spec_dir: :string,
          base: :string,
          output: :string,
          open: :boolean
        ],
        aliases: [r: :root, o: :output]
      )

    validate_args!(rest, invalid)

    root = opts[:root] || File.cwd!()
    spec_dir = opts[:spec_dir] || SpecLedEx.detect_spec_dir(root)
    authored_dir = SpecLedEx.detect_authored_dir(root, spec_dir)
    output_path = output_path(opts[:output], root)

    index = SpecLedEx.index(root, spec_dir: spec_dir, authored_dir: authored_dir)
    view = SpecLedEx.Review.build_view(index, root, base: opts[:base])
    html = SpecLedEx.Review.Html.render(view) |> IO.iodata_to_binary()

    File.mkdir_p!(Path.dirname(output_path))
    File.write!(output_path, html)

    Mix.shell().info(
      "spec.review wrote #{Path.relative_to(output_path, root)} (#{byte_size(html)} bytes)"
    )

    Mix.shell().info(
      "  base=#{view.meta.base_ref} head=#{view.meta.head_ref} affected_subjects=#{length(view.affected_subjects)} findings=#{length(view.all_findings)}"
    )

    if opts[:open], do: maybe_open(output_path)

    :ok
  end

  defp output_path(nil, root), do: Path.join([root, "_build", "spec_review.html"])

  defp output_path(path, root) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, root)
  end

  defp maybe_open(path) do
    binary =
      case :os.type() do
        {:unix, :darwin} -> "open"
        {:unix, _} -> "xdg-open"
        _ -> nil
      end

    if binary && System.find_executable(binary) do
      _ = System.cmd(binary, [path])
      :ok
    else
      :ok
    end
  end

  defp validate_args!([], []), do: :ok

  defp validate_args!(rest, invalid) do
    invalid_flags = Enum.map(invalid, fn {flag, _value} -> flag end)
    extra_args = Enum.map(rest, &inspect/1)
    details = Enum.join(invalid_flags ++ extra_args, ", ")
    Mix.raise("Invalid arguments for spec.review: #{details}")
  end
end
