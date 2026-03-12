defmodule CredoChecks.NoArbitraryHexColors do
  @moduledoc """
  Prevents arbitrary hex color values in Tailwind class strings.

  Hardcoded hex colors bypass the design system's color palette and make
  consistency impossible to maintain. Use a named color scale instead:

      # Bad
      class="bg-[#333] text-[#ff6600] border-[#ccc]"

      # Good
      class="bg-tymeslot-800 text-brand border-tymeslot-300"

  Available scales: `tymeslot-*`, `turquoise-*`, `cyan-*`, `brand`.
  """

  use Credo.Check,
    base_priority: :low,
    category: :design,
    exit_status: 0,
    explanations: [
      check: """
      Avoid arbitrary hex colors in Tailwind classes (e.g. `bg-[#333]`).
      Use a named color from the design system instead.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile

  @regex ~r/(?:text|bg|border|ring|from|to|via|fill|stroke|outline|accent|decoration|shadow|divide|placeholder)-\[#[0-9a-fA-F]+\]/

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: list()
  def run(%SourceFile{} = source_file, params) do
    if skip_file?(source_file.filename) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> SourceFile.lines()
      |> Enum.reduce([], fn {line_no, line}, issues ->
        case Regex.run(@regex, line) do
          [match | _] ->
            [issue_for(issue_meta, line_no, match) | issues]

          nil ->
            issues
        end
      end)
    end
  end

  defp skip_file?(filename) do
    String.contains?(filename, "no_arbitrary_hex_colors.ex") or
      String.contains?(filename, "/assets/")
  end

  defp issue_for(issue_meta, line_no, trigger) do
    format_issue(issue_meta,
      message:
        "Avoid arbitrary hex colors (`#{trigger}`). Use a named color scale (e.g. `tymeslot-*`, `turquoise-*`, `cyan-*`).",
      line_no: line_no,
      trigger: trigger
    )
  end
end
