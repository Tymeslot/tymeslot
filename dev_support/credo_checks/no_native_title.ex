defmodule CredoChecks.NoNativeTitle do
  @moduledoc """
  Flags a native `title=` attribute in HEEx markup.

  A native title needs a mouse hover: it never shows on touch or keyboard
  focus, and screen readers read it inconsistently, so a reason a control is
  unavailable, or any other information, must not live only there. Use the
  `<.tooltip>` component, or visible text linked by `aria-describedby`.

  Matches lowercase HTML elements and the components that forward global
  attributes to an element (`<.link>`, the button components, `<.icon>`,
  `<.pill>`), so
  the `title` attribute of a `<.card>` or a `<.confirm_modal>`, which is a
  heading, is not touched. `<iframe>` is exempt: a title is its accessible
  name.

  A `title` that only repeats text already visible on the element (typically
  so a truncated value can be read in full) can stay, with a HEEx comment
  directly above the tag saying why:

      <%!-- native-title: repeats the event title, which can truncate. --%>
      <div title={@event.summary} class="truncate">{@event.summary}</div>

  It also requires an `id` on an `<.icon_button>`, `<.action_button>` or
  `<.loading_button>` with a `tooltip`, which that tooltip's
  `aria-describedby` link is built from.
  """

  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      Don't put information in a native `title=` attribute. Use `<.tooltip>`
      (shown on hover, focus and touch) or visible text with `aria-describedby`.
      A title that only repeats visible, possibly truncated, text can stay with
      a `<%!-- native-title: <reason> --%>` comment directly above the tag. A
      button component with a `tooltip` needs an `id`.
      """
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile
  alias CredoChecks.HtmlTags

  @html_tag "[a-z][a-z0-9-]*"
  # Components that pass a global `title` straight onto an HTML element.
  @forwarding_tags "(?:[A-Z][\\w.]*)?\\.(?:link|icon|icon_button|action_button|action_link|loading_button|pill)"
  @tag_pattern "#{@html_tag}|#{@forwarding_tags}"
  @exempt_elements ["iframe"]
  @exemption_regex ~r/(^|\s)native-title:\s*\S/
  @title_attr ~r/\stitle=/
  @tooltip_buttons ~r/(icon_button|action_button|loading_button)$/
  @tooltip_attr ~r/\stooltip=/
  @id_attr ~r/\sid=/
  @spread_attrs ~r/\s\{@\w+\}/

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    if checked?(filename) do
      issue_meta = IssueMeta.for(source_file, params)

      source_file
      |> HtmlTags.tags(@tag_pattern)
      |> Enum.flat_map(&issues_for(&1, issue_meta))
    else
      []
    end
  end

  defp checked?(filename), do: filename |> Path.relative_to_cwd() |> String.starts_with?("lib/")

  defp issues_for(%{name: name, line_no: line_no, text: text, comment: comment}, issue_meta) do
    attrs = strip_values(text)

    title_issues(name, line_no, attrs, comment, issue_meta) ++
      tooltip_issues(name, line_no, attrs, text, issue_meta)
  end

  defp title_issues(name, line_no, attrs, comment, issue_meta) do
    if flagged_title?(name, attrs, comment) do
      [
        format_issue(issue_meta,
          message:
            "Don't carry information in a native `title=`; use `<.tooltip>` or visible text with `aria-describedby`.",
          line_no: line_no,
          trigger: "title="
        )
      ]
    else
      []
    end
  end

  defp flagged_title?(name, attrs, comment) do
    tag = String.downcase(name)

    html_or_forwarding?(name) and tag not in @exempt_elements and
      Regex.match?(@title_attr, attrs) and not exempt?(comment)
  end

  # A capitalised bare name (`<Foo `, unlikely but matched case-insensitively)
  # is a component reference, not an element.
  defp html_or_forwarding?(name),
    do: String.first(name) =~ ~r/[a-z.]/ or String.contains?(name, ".")

  # A spread such as `{@rest}` can carry the `id`, so it is not flagged.
  defp tooltip_issues(name, line_no, attrs, text, issue_meta) do
    if Regex.match?(@tooltip_buttons, name) and Regex.match?(@tooltip_attr, attrs) and
         not Regex.match?(@id_attr, attrs) and not Regex.match?(@spread_attrs, text) do
      [
        format_issue(issue_meta,
          message:
            "Give a button with a `tooltip` an `id`, so the tooltip can be linked by `aria-describedby`.",
          line_no: line_no,
          trigger: "tooltip="
        )
      ]
    else
      []
    end
  end

  defp exempt?(nil), do: false
  defp exempt?(comment), do: Regex.match?(@exemption_regex, comment)

  # Removes quoted values and `{...}` expressions, so `title=` inside either
  # (`alt="a title=b"`, a `phx-value-x={%{title: 1}}`) is not an attribute.
  defp strip_values(text) do
    text
    |> then(&Regex.replace(~r/"[^"]*"/, &1, "\"\""))
    |> strip_braces()
  end

  defp strip_braces(text) do
    stripped = Regex.replace(~r/\{[^{}]*\}/, text, "")
    if stripped == text, do: text, else: strip_braces(stripped)
  end
end
