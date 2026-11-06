defmodule CredoChecks.UseCoreInputs do
  @moduledoc """
  Ensures that core components are used instead of raw HTML input tags or standard Phoenix form helpers.

  Raw `<input>`, `<textarea>`, and `<select>` tags, as well as `Phoenix.HTML.Form` helpers,
  should be avoided in favor of standardized components in `TymeslotWeb.Components.CoreComponents`.

  Tags are read whole, so one whose attributes the formatter has wrapped onto
  the following lines is caught too. A control `input/1` cannot render is
  exempted by a `<%!-- raw-input: <reason> --%>` comment directly above it.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      Ensures that core components are used instead of raw HTML input tags or standard Phoenix form helpers.

      Raw `<input>`, `<textarea>`, and `<select>` tags, as well as `Phoenix.HTML.Form` helpers,
      should be avoided in favor of standardized components in `TymeslotWeb.Components.CoreComponents`.
      """,
      params: []
    ]

  alias Credo.IssueMeta
  alias Credo.SourceFile
  alias CredoChecks.HtmlTags

  @helpers ~w(text_input textarea select password_input email_input number_input checkbox
              radio_button date_input time_input datetime_local_input color_input file_input
              range_input search_input telephone_input url_input label)a

  # The modules the helpers live in: `Phoenix.HTML.Form` before Phoenix HTML
  # 4, `PhoenixHTMLHelpers.Form` since.
  @form_modules [[:Phoenix, :HTML, :Form], [:PhoenixHTMLHelpers, :Form]]

  # Hidden inputs are ignored, as they are often used for CSRF or internal
  # state. The attribute is looked for in the whole tag, which the formatter
  # may have wrapped over several lines.
  @hidden_regex ~r/\stype=["']hidden["']/i

  # A raw control that `input/1` cannot render (a radio drawn as an option
  # card, a file input behind a styled button) is exempted where it stands,
  # by a HEEx comment directly above the tag that says why:
  #
  #     <%!-- raw-input: radio drawn by the option card around it --%>
  #     <input type="radio" ... />
  #
  # `# credo:disable-for-next-line` cannot do this: it is an Elixir comment,
  # and the tag sits inside a `~H` template. The reason is required.
  @exemption_regex ~r/^raw-input:\s*\S/

  @doc false
  @impl Credo.Check
  @spec run(SourceFile.t(), any) :: list()
  def run(%SourceFile{} = source_file, params) do
    # Skip the file that defines the core components themselves to avoid circular issues
    filename = source_file.filename

    if String.contains?(filename, "core_components/forms.ex") or
         String.contains?(filename, "use_core_inputs.ex") or
         String.contains?(filename, "form_system.ex") or
         String.contains?(filename, "controllers/dev/") or
         String.ends_with?(filename, "_test.exs") do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      tag_issues(source_file, issue_meta) ++ helper_issues(source_file, issue_meta)
    end
  end

  # Tags live in HEEx, which the AST holds as strings, so these are read from
  # the source text, whole, by `CredoChecks.HtmlTags`.
  defp tag_issues(source_file, issue_meta) do
    for %{name: tag, line_no: line_no, text: text, comment: comment} <-
          HtmlTags.tags(source_file, "input|textarea|select"),
        not Regex.match?(@hidden_regex, text),
        not exempt?(comment) do
      format_issue(issue_meta,
        message:
          "Avoid using raw `<#{tag}>` tags. Use `TymeslotWeb.Components.CoreComponents.Forms.input/1` instead.",
        line_no: line_no,
        trigger: "<#{tag}"
      )
    end
  end

  defp exempt?(nil), do: false
  defp exempt?(comment), do: Regex.match?(@exemption_regex, comment)

  # Helpers are found as calls: qualified by a form module or an alias of
  # one, or unqualified where a form module is imported. Any other module's
  # function of the same name (`Registry.select/2`, say) is not one.
  defp helper_issues(source_file, issue_meta) do
    {aliases, imported?} = Credo.Code.prewalk(source_file, &collect_names/2, {%{}, false})

    source_file
    |> Credo.Code.prewalk(&find_helpers(&1, &2, aliases, imported?, issue_meta))
    |> Enum.reverse()
  end

  defp collect_names(
         {:alias, _meta, [{:__aliases__, _, segments} | opts]} = ast,
         {aliases, imported?}
       ) do
    # `as:` may come with other options, such as `warn: false`.
    name =
      case opts do
        [[_ | _] = keyword] ->
          case Keyword.get(keyword, :as) do
            {:__aliases__, _, [as]} -> as
            _no_as -> List.last(segments)
          end

        _no_options ->
          List.last(segments)
      end

    {ast, {Map.put(aliases, name, segments), imported?}}
  end

  defp collect_names(
         {:alias, _meta, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _opts]} = ast,
         {aliases, imported?}
       ) do
    aliases =
      for {:__aliases__, _, segments} <- children, into: aliases do
        {List.last(segments), base ++ segments}
      end

    {ast, {aliases, imported?}}
  end

  defp collect_names(
         {:import, _meta, [{:__aliases__, _, segments} | _opts]} = ast,
         {aliases, imported?}
       ),
       do: {ast, {aliases, imported? or segments in @form_modules}}

  # `use PhoenixHTMLHelpers` imports the form helpers along with the rest.
  defp collect_names(
         {:use, _meta, [{:__aliases__, _, [:PhoenixHTMLHelpers]} | _opts]} = ast,
         {aliases, _imported?}
       ),
       do: {ast, {aliases, true}}

  defp collect_names(ast, acc), do: {ast, acc}

  defp find_helpers(
         {{:., _, [{:__aliases__, _, segments}, helper]}, meta, args} = ast,
         issues,
         aliases,
         _imported?,
         issue_meta
       )
       when helper in @helpers and is_list(args) do
    if resolve(segments, aliases) in @form_modules,
      do: {ast, [helper_issue(issue_meta, helper, meta, ".#{helper}") | issues]},
      else: {ast, issues}
  end

  defp find_helpers({helper, meta, args} = ast, issues, _aliases, true, issue_meta)
       when helper in @helpers and is_list(args) and args != [],
       do: {ast, [helper_issue(issue_meta, helper, meta, Atom.to_string(helper)) | issues]}

  defp find_helpers(ast, issues, _aliases, _imported?, _issue_meta), do: {ast, issues}

  defp resolve([first | rest], aliases) do
    case Map.fetch(aliases, first) do
      {:ok, segments} -> segments ++ rest
      :error -> [first | rest]
    end
  end

  defp helper_issue(issue_meta, helper, meta, trigger) do
    component = if helper == :label, do: "label/1", else: "input/1"

    format_issue(issue_meta,
      message:
        "Avoid using `Phoenix.HTML.Form.#{helper}/3` helpers. Use `TymeslotWeb.Components.CoreComponents.Forms.#{component}` instead.",
      line_no: meta[:line],
      trigger: trigger
    )
  end
end
