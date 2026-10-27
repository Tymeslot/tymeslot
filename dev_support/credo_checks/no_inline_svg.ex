defmodule CredoChecks.NoInlineSvg do
  @moduledoc """
  Ensures icons are drawn with `<.icon>` instead of a hand-written `<svg>`.

  Every icon goes through the one icon component
  (`TymeslotWeb.Components.CoreComponents.Icons`): a Heroicon by its `hero-…`
  name, or a custom icon kept as an SVG file in the app's `priv/icons`. A
  hand-copied `<svg>` drifts from the set (an old Heroicons path, its own
  stroke weight, no `aria-hidden`), which is how the app ended up with three
  icon systems.

  Artwork that is not an icon (an illustration, a chart drawn from data, an
  SVG document generated for an image or an email) is exempt by listing its
  file in the `allowed_files` param in `.credo.exs`. Only `lib/` is checked.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    param_defaults: [allowed_files: []],
    explanations: [
      check: """
      Draw icons with `<.icon name="…">`, never a hand-written `<svg>`.

          <.icon name="hero-check-circle" class="w-5 h-5 text-turquoise-500" />

      A heavier stroke is a class (`stroke-2`), not a copied path. When no
      Heroicon fits, add the SVG to `priv/icons` (in SaaS when only SaaS
      shows it) and draw it by its file name. Artwork that is not an icon goes
      in the check's `allowed_files` list in `.credo.exs`.
      """,
      params: [
        allowed_files: "Path suffixes of files allowed to contain `<svg` (artwork, not icons)."
      ]
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  # An opening tag with attributes, or one the formatter split after the tag
  # name. A bare `<svg>` is how prose and docs name the element, not markup.
  @svg_tag ~r/<svg(\s|$)/

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    allowed = Params.get(params, :allowed_files, __MODULE__)

    if checked?(filename, allowed) do
      issue_meta = IssueMeta.for(source_file, params)

      for {line_no, line} <- SourceFile.lines(source_file), Regex.match?(@svg_tag, line) do
        format_issue(issue_meta,
          message: "Draw icons with `<.icon>`, not a hand-written `<svg>`.",
          line_no: line_no,
          trigger: "<svg"
        )
      end
    else
      []
    end
  end

  defp checked?(filename, allowed) do
    path = Path.relative_to_cwd(filename)

    String.starts_with?(path, "lib/") and not Enum.any?(allowed, &String.ends_with?(path, &1))
  end
end
