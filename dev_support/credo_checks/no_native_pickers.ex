defmodule CredoChecks.NoNativePickers do
  @moduledoc """
  Keeps browser-drawn pickers out of the product.

  A native picker looks different in every browser (on Linux the colour control
  opens the GTK dialog) and ignores the user's Tymeslot locale, so a control
  that has an in-house replacement must not come back as `<input type="...">`
  or `<.input type="...">`.

  Only types with an in-house replacement are listed. `range` stays allowed on
  purpose: the colour picker's hue slider is a restyled native range.

  Tags are read whole, so a `type` the formatter has wrapped onto a later line
  is caught too.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      Use the in-house picker instead of a browser-drawn control.

      For a colour, that is `colour_picker_widget/1` in
      `TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.Pickers.ColourPickerWidget`.
      """,
      params: []
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile
  alias CredoChecks.HtmlTags

  @banned_types ~w(color)
  @type_regex ~r/\stype=(?:["'](?<type>[\w-]+)["']|\{\s*"(?<expr>[\w-]+)"\s*\})/i

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)

    for %{name: name, line_no: line_no, text: text} <-
          HtmlTags.tags(source_file, ~S"input|(?:[A-Z][\w.]*)?\.input"),
        type = banned_type(text) do
      format_issue(issue_meta,
        message: "`type=\"#{type}\"` opens the browser's own picker. Use the in-house one.",
        line_no: line_no,
        trigger: "<#{name}"
      )
    end
  end

  defp banned_type(text) do
    case Regex.named_captures(@type_regex, text) do
      %{"type" => type, "expr" => expr} ->
        Enum.find([type, expr], &(String.downcase(&1) in @banned_types))

      nil ->
        nil
    end
  end
end
