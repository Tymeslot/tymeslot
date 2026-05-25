defmodule CredoChecks.UseCoreInputs do
  @moduledoc """
  Ensures that core components are used instead of raw HTML input tags or standard Phoenix form helpers.

  Raw `<input>`, `<textarea>`, and `<select>` tags, as well as `Phoenix.HTML.Form` helpers,
  should be avoided in favor of standardized components in `TymeslotWeb.Components.CoreComponents`.
  """

  use Credo.Check,
    base_priority: :high,
    category: :readability,
    exit_status: 0,
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
      lines = SourceFile.lines(source_file)

      # Regex to find raw <input, <textarea, <select tags
      # We ignore hidden inputs as they are often used for CSRF or internal state.
      input_regex = ~r/<(input|textarea|select)(?![^>]*type=["']hidden["'])[\s\/>]/i

      # Regex to find standard Phoenix form helpers in .ex files
      helper_regex =
        ~r/\.(text_input|textarea|select|password_input|email_input|number_input|checkbox|radio_button|date_input|time_input|datetime_local_input|color_input|file_input|range_input|search_input|telephone_input|url_input|label)\(/

      Enum.reduce(lines, [], fn {line_no, line}, issues ->
        cond do
          Regex.run(input_regex, line) ->
            [issue_for(issue_meta, line_no, line, :tag) | issues]

          Regex.run(helper_regex, line) ->
            [issue_for(issue_meta, line_no, line, :helper) | issues]

          true ->
            issues
        end
      end)
    end
  end

  defp issue_for(issue_meta, line_no, line, type) do
    {tag, trigger} =
      case type do
        :tag ->
          tag =
            case Regex.run(~r/<(input|textarea|select)/i, line) do
              [_, tag] -> tag
              _other -> "input"
            end

          {tag, "<#{tag}"}

        :helper ->
          helper =
            case Regex.run(
                   ~r/\.(text_input|textarea|select|password_input|email_input|number_input|checkbox|radio_button|date_input|time_input|datetime_local_input|color_input|file_input|range_input|search_input|telephone_input|url_input|label)\(/,
                   line
                 ) do
              [_, helper] -> helper
              _other -> "input_helper"
            end

          {helper, ".#{helper}"}
      end

    message =
      if type == :tag do
        "Avoid using raw `<#{tag}>` tags. Use `TymeslotWeb.Components.CoreComponents.input/1` instead."
      else
        component = if tag == "label", do: "label/1", else: "input/1"

        "Avoid using `Phoenix.HTML.Form.#{tag}/3` helpers. Use `TymeslotWeb.Components.CoreComponents.#{component}` instead."
      end

    format_issue(issue_meta,
      message: message,
      line_no: line_no,
      trigger: trigger
    )
  end
end
