defmodule CredoChecks.NoNativeTitle do
  @moduledoc """
  Flags a native `title=` attribute in HEEx markup.

  A native title needs a mouse hover: it never shows on touch or keyboard
  focus, and screen readers read it inconsistently, so a reason a control is
  unavailable, or any other information, must not live only there. Use the
  `<.tooltip>` component, or visible text linked by `aria-describedby`.

  Matches lowercase HTML elements, and every function component that would
  forward a `title` onto an element: one that declares a `:global` attribute
  (which accepts `title`, as every global attribute does) and no `title`
  attribute of its own, such as `<.input>`, `<.select>`, the button
  components, `<.icon>` and `<.pill>`, plus Phoenix's `<.link>`. The set is
  read from the `attr` declarations under `lib/` of the repo being checked and
  of Core (`:component_sources`), so a new component is covered the day it is
  written. A component that declares `attr :title`, where the title is a
  heading (`<.card>`, `<.confirm_modal>`), is not touched, nor is one with no
  `:global` attribute, which cannot forward it. Components are matched by
  name: when two components share a name and one of them declares a `title`,
  the name is left alone. `<iframe>` is exempt: a title is its accessible
  name.

  A `title` that only repeats text already visible on the element (typically
  so a truncated value can be read in full) can stay, with a HEEx comment
  directly above the tag saying why:

      <%!-- native-title: repeats the event title, which can truncate. --%>
      <div title={@event.summary} class="truncate">{@event.summary}</div>

  It also requires an `id` on an `<.icon_button>`, `<.action_button>` or
  `<.loading_button>` with a `tooltip`, which that tooltip's
  `aria-describedby` link is built from. A spread of a `:global` attribute
  declared in the same file (`{@rest}` in a wrapper that passes its caller's
  attributes on) can carry the caller's `id`, so it satisfies the rule; the
  caller's own tag is checked in turn. Any other spread does not: whether an
  arbitrary map holds an `id` cannot be read from the source, so the `id` is
  given as an attribute.

  Two gaps are known and accepted:

    * `.heex` template files. Credo reads only `.ex` and `.exs` files, and
      parses each as Elixir: a `.heex` file listed in `.credo.exs` would fail
      as a syntax error rather than be checked. The check's test runs it over
      every `lib/**/*.heex` file instead.
    * A `title` built in Elixir and spread onto a tag (`<button {@attrs}>`,
      with `attrs` holding `title: ...`). Telling such a key from the many
      maps with a `title` key (headings, class tables) needs data flow the
      source text does not give.
  """

  use Credo.Check,
    base_priority: :high,
    param_defaults: [
      component_sources: [
        "lib/**/*.ex",
        Path.join(Path.expand("../../lib", __DIR__), "**/*.ex")
      ]
    ],
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

  alias Credo.Check.Params
  alias Credo.IssueMeta
  alias Credo.SourceFile
  alias CredoChecks.HtmlTags

  @html_tag "[a-z][a-z0-9-]*"
  @component_tag "(?:[A-Z][\\w.]*)?\\.\\w+"
  @tag_pattern "#{@html_tag}|#{@component_tag}"
  # Phoenix's own components that forward a global `title`; they are not in lib/.
  @builtin_forwarding ["link"]
  @attr_line ~r/^\s*attr\s+:(\w+),\s*:(\w+)/
  @def_line ~r/^\s*defp?\s+(\w+)\(/
  @exempt_elements ["iframe"]
  @exemption_regex ~r/(^|\s)native-title:\s*\S/
  @title_attr ~r/\stitle=/
  @tooltip_buttons ~r/(icon_button|action_button|loading_button)$/
  @tooltip_attr ~r/\stooltip=/
  @id_attr ~r/\sid=/
  @spread_attrs ~r/\s\{@(\w+)\}/

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), keyword()) :: [Credo.Issue.t()]
  def run(%SourceFile{filename: filename} = source_file, params) do
    if checked?(filename) do
      issue_meta = IssueMeta.for(source_file, params)

      context = %{
        forwarding: cached_forwarding(Params.get(params, :component_sources, __MODULE__)),
        globals: source_file |> SourceFile.source() |> global_attrs()
      }

      source_file
      |> HtmlTags.tags(@tag_pattern)
      |> Enum.flat_map(&issues_for(&1, context, issue_meta))
    else
      []
    end
  end

  defp checked?(filename), do: filename |> Path.relative_to_cwd() |> String.starts_with?("lib/")

  defp issues_for(tag, context, issue_meta) do
    %{name: name, line_no: line_no, text: text, comment: comment} = tag
    attrs = strip_values(text)

    title_issues(name, line_no, attrs, comment, context, issue_meta) ++
      tooltip_issues(name, line_no, attrs, text, context, issue_meta)
  end

  defp title_issues(name, line_no, attrs, comment, context, issue_meta) do
    if flagged_title?(name, attrs, comment, context) do
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

  defp flagged_title?(name, attrs, comment, context) do
    html_or_forwarding?(name, context.forwarding) and
      String.downcase(name) not in @exempt_elements and
      Regex.match?(@title_attr, attrs) and not exempt?(comment)
  end

  # `<.input` and `<Form.input` are components; `<span` is an element. The
  # pattern ignores case, so a capitalised bare `<Foo` is matched too, and is
  # neither.
  defp html_or_forwarding?(name, forwarding) do
    if String.contains?(name, ".") do
      name |> String.split(".") |> List.last() |> then(&MapSet.member?(forwarding, &1))
    else
      String.first(name) =~ ~r/[a-z]/
    end
  end

  # A spread of a `:global` attribute (a wrapper's `{@rest}`) can carry the
  # caller's `id`; any other spread is not taken to.
  defp tooltip_issues(name, line_no, attrs, text, context, issue_meta) do
    if Regex.match?(@tooltip_buttons, name) and Regex.match?(@tooltip_attr, attrs) and
         not Regex.match?(@id_attr, attrs) and not global_spread?(text, context.globals) do
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

  defp global_spread?(text, globals) do
    @spread_attrs
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.any?(fn [attr] -> MapSet.member?(globals, attr) end)
  end

  defp global_attrs(source) do
    ~r/^\s*attr\s+:(\w+),\s*:global\b/m
    |> Regex.scan(source, capture: :all_but_first)
    |> MapSet.new(fn [attr] -> attr end)
  end

  # Reading every component source once per run, not once per file checked.
  defp cached_forwarding(globs) do
    key = {__MODULE__, :forwarding, globs}

    case :persistent_term.get(key, nil) do
      nil ->
        forwarding =
          globs
          |> Enum.flat_map(&Path.wildcard/1)
          |> Enum.uniq_by(&Path.expand/1)
          |> Enum.map(&File.read!/1)
          |> forwarding_components()

        :persistent_term.put(key, forwarding)
        forwarding

      forwarding ->
        forwarding
    end
  end

  @doc """
  The names of the function components in `sources` (file contents) that
  forward a global `title`: they declare a `:global` attribute and no `title`
  attribute, and no other component of the same name declares one. Phoenix's
  `link` is always included.
  """
  @spec forwarding_components([String.t()]) :: MapSet.t(String.t())
  def forwarding_components(sources) do
    components = Enum.flat_map(sources, &components/1)

    titled =
      for {name, attrs} <- components,
          Enum.any?(attrs, &match?({"title", _}, &1)),
          into: MapSet.new(),
          do: name

    global =
      for {name, attrs} <- components,
          Enum.any?(attrs, &match?({_, "global"}, &1)),
          into: MapSet.new(),
          do: name

    global
    |> MapSet.difference(titled)
    |> MapSet.union(MapSet.new(@builtin_forwarding))
  end

  # `{name, [{attr, type}]}` for each function preceded by `attr` declarations.
  # Later clauses of a multi-clause component carry none and are dropped.
  defp components(source) do
    {_pending, components} =
      source
      |> String.split("\n")
      |> Enum.reduce({[], []}, fn line, {pending, acc} ->
        cond do
          match = Regex.run(@attr_line, line, capture: :all_but_first) ->
            {[List.to_tuple(match) | pending], acc}

          match = Regex.run(@def_line, line, capture: :all_but_first) ->
            {[], if(pending == [], do: acc, else: [{hd(match), pending} | acc])}

          true ->
            {pending, acc}
        end
      end)

    components
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
