defmodule Tymeslot.Integrations.Video.TemplateSyntax do
  @moduledoc """
  Template syntax rules for custom video meeting URLs.

  The only supported template variable is `{{meeting_id}}`: exactly that, in
  lowercase, in the path or query string. It is replaced with a per-meeting hash
  when a room is created. A URL without it is a static room that every meeting
  shares, which is a legitimate choice.

  Anything that looks like an attempt at the variable but is not written exactly
  (`{meeting_id}`, `{{Meeting_ID}}`, `{{ meeting_id }}`, `[[meeting_id]]`), any
  other double-brace variable, and the variable inside the fragment are refused:
  room creation only recognises the exact form, so each of these would silently
  give every booking the same room.

  `validate/1` is the save-time rule and `analyze/1` is the live preview shown
  while typing. Both are derived from one classification, so a URL that
  `validate/1` refuses is always shown as a warning, and the message the user
  sees in the preview is the one the save returns.

  Braces on their own are not refused: a permanent Microsoft Teams link carries
  a JSON context such as `{"Tid":"…"}` once percent-decoded. A bare `meeting_id`
  without brackets (`?meeting_id=123`) is only flagged in the preview, since it
  is a legitimate static query parameter.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video.TemplateConfig

  @type analysis_result ::
          {:ok, :valid_template | :static | :empty, String.t(), String.t()}
          | {:warning, atom(), String.t(), String.t()}

  @doc ~S"""
  Checks a custom meeting URL against the template syntax rules.

  Returns `:ok` for a static URL or a correctly written template, and
  `{:error, message}` when the URL contains a malformed or unsupported template
  variable, or places `{{meeting_id}}` in the fragment.

  ## Examples

      iex> validate("https://meet.example.com/{{meeting_id}}")
      :ok

      iex> validate("https://meet.example.com/my-room")
      :ok

      iex> validate("https://meet.example.com/{meeting_id}")
      {:error, "Use double curly brackets: {{meeting_id}} not {meeting_id}"}
  """
  @spec validate(String.t()) :: :ok | {:error, String.t()}
  def validate(url) when is_binary(url) do
    case classify(url) do
      {:invalid, _type, message} -> {:error, message}
      _acceptable -> :ok
    end
  end

  @doc ~S"""
  Analyzes a URL template string and returns the result type, preview, and message.

  ## Examples

      iex> analyze("https://jitsi.org/{{meeting_id}}")
      {:ok, :valid_template, "https://jitsi.org/a1b2c3d4e5f67890", "Template variable detected: {{meeting_id}}"}

      iex> analyze("https://jitsi.org/{meeting_id}")
      {:warning, :single_curly_brackets, "https://jitsi.org/{meeting_id}", "Use double curly brackets: {{meeting_id}} not {meeting_id}"}

      iex> analyze("https://meet.example.com/room")
      {:ok, :static, "https://meet.example.com/room", "Static URL - all meetings will use the same room"}

      iex> analyze("https://jitsi.org/room#{{meeting_id}}")
      {:warning, :template_in_fragment, "https://jitsi.org/room#{{meeting_id}}", "Template in fragment (#) won't work..."}
  """
  @spec analyze(String.t() | nil) :: analysis_result()
  def analyze(url) when is_binary(url) and url != "" do
    case classify(url) do
      :valid_template ->
        preview =
          String.replace(url, TemplateConfig.template_variable(), TemplateConfig.sample_hash())

        {:ok, :valid_template, preview,
         dgettext("dashboard_integrations", "Template variable detected: {{meeting_id}}")}

      :static ->
        {:ok, :static, url,
         dgettext("dashboard_integrations", "Static URL - all meetings will use the same room")}

      {_severity, type, message} ->
        {:warning, type, url, message}
    end
  end

  def analyze(_url),
    do: {:ok, :empty, "", dgettext("dashboard_integrations", "Enter a URL to see a preview")}

  # One classification feeds both entry points. `:invalid` blocks a save;
  # `:advisory` is only a preview hint.
  defp classify(url) do
    # Malformed tokens are looked for in what is left once every correctly
    # written variable is removed, so a valid template cannot mask a stray one.
    remainder = String.replace(url, TemplateConfig.template_variable(), "")

    cond do
      template_in_fragment?(url) ->
        {:invalid, :template_in_fragment,
         dgettext(
           "dashboard_integrations",
           "Template in fragment (#) won't work - fragments aren't sent to servers. Use path instead: https://example.com/{{meeting_id}}"
         )}

      malformed_template?(remainder) ->
        describe_malformed_template(remainder)

      remainder != url ->
        :valid_template

      String.contains?(url, "meeting_id") ->
        {:advisory, :no_brackets,
         dgettext(
           "dashboard_integrations",
           "Found 'meeting_id' without brackets - use {{meeting_id}}"
         )}

      true ->
        :static
    end
  end

  defp template_in_fragment?(url) do
    case URI.parse(url) do
      %URI{fragment: fragment} when is_binary(fragment) ->
        String.contains?(fragment, TemplateConfig.template_variable())

      _no_fragment ->
        false
    end
  end

  # The blocking rule: any double-brace token, or a meeting-id token touching
  # a bracket of any kind. Deliberately independent of the descriptive checks
  # below, which only choose the message.
  defp malformed_template?(remainder) do
    Regex.match?(~r/\{\{[^{}]*\}\}/, remainder) or
      Regex.match?(~r/[{\[(<]\s*meeting[\s_-]*id|meeting[\s_-]*id\s*[}\])>]/i, remainder)
  end

  defp describe_malformed_template(remainder) do
    {type, message} =
      cond do
        wrong_case?(remainder) ->
          {:wrong_case,
           dgettext(
             "dashboard_integrations",
             "Use lowercase: {{meeting_id}} not {{MEETING_ID}} or {{Meeting_Id}}"
           )}

        mismatched_brackets?(remainder) ->
          mismatched_brackets_message(remainder)

        missing_brackets?(remainder) ->
          missing_brackets_message(remainder)

        wrong_bracket_type?(remainder) ->
          wrong_bracket_type_message(remainder)

        variable_name_issue?(remainder) ->
          variable_name_issue_message(remainder)

        unknown_variable?(remainder) ->
          {:unknown_variable,
           dgettext(
             "dashboard_integrations",
             "Unknown template variable. Only {{meeting_id}} is supported"
           )}

        true ->
          {:invalid_template_syntax,
           dgettext(
             "dashboard_integrations",
             "Write the template variable exactly as {{meeting_id}}"
           )}
      end

    {:invalid, type, message}
  end

  # The checks below only choose which message describes a malformed token.
  # They run on the URL with every correct {{meeting_id}} already removed.

  # Wrong case (e.g. {{MEETING_ID}}, {{Meeting_Id}})
  defp wrong_case?(url), do: Regex.match?(~r/\{\{meeting_id\}\}/i, url)

  # Mismatched brackets detection
  defp mismatched_brackets?(url) do
    Regex.match?(~r/\{\{meeting_id\)|{{meeting_id\]\]|{{meeting_id>/i, url) or
      Regex.match?(~r/\{meeting_id\}\}|\[\[meeting_id\}\}|<meeting_id\}\}/i, url) or
      Regex.match?(~r/\(\(meeting_id\}\}|\[meeting_id\]\]|{meeting_id\]/i, url)
  end

  defp mismatched_brackets_message(url) do
    cond do
      Regex.match?(~r/\{\{meeting_id\)/i, url) ->
        {:mismatched_open_double_close_paren,
         dgettext(
           "dashboard_integrations",
           "Mismatched brackets: {{meeting_id) should be {{meeting_id}}"
         )}

      Regex.match?(~r/\{meeting_id\}\}/i, url) ->
        {:mismatched_open_single_close_double,
         dgettext(
           "dashboard_integrations",
           "Mismatched brackets: {meeting_id}} should be {{meeting_id}}"
         )}

      Regex.match?(~r/\{\{meeting_id\]\]/i, url) ->
        {:mismatched_curly_square,
         dgettext(
           "dashboard_integrations",
           "Mismatched brackets: {{meeting_id]] should be {{meeting_id}}"
         )}

      Regex.match?(~r/\[\[meeting_id\}\}/i, url) ->
        {:mismatched_square_curly,
         dgettext(
           "dashboard_integrations",
           "Mismatched brackets: [[meeting_id}} should be {{meeting_id}}"
         )}

      true ->
        {:mismatched_brackets,
         dgettext("dashboard_integrations", "Mismatched brackets detected - use {{meeting_id}}")}
    end
  end

  # Missing brackets detection
  defp missing_brackets?(url) do
    Regex.match?(~r/\{\{meeting_id\}?(?!\})/i, url) or
      Regex.match?(~r/(?<!\{)\{meeting_id\}\}/i, url) or
      Regex.match?(~r/meeting_id\}\}(?!\})/i, url)
  end

  defp missing_brackets_message(url) do
    cond do
      Regex.match?(~r/\{\{meeting_id(?!\}\})/i, url) ->
        {:missing_closing_brackets,
         dgettext("dashboard_integrations", "Missing closing brackets - should be {{meeting_id}}")}

      Regex.match?(~r/(?<!\{)meeting_id\}\}/i, url) ->
        {:missing_opening_brackets,
         dgettext("dashboard_integrations", "Missing opening brackets - should be {{meeting_id}}")}

      true ->
        {:missing_brackets,
         dgettext("dashboard_integrations", "Missing brackets - use {{meeting_id}}")}
    end
  end

  # Wrong bracket types
  defp wrong_bracket_type?(url) do
    Regex.match?(~r/\{meeting_id\}|\[\[meeting_id\]\]|\(\(meeting_id\)\)|<+meeting_id>+/i, url)
  end

  defp wrong_bracket_type_message(url) do
    cond do
      Regex.match?(~r/\{meeting_id\}/i, url) ->
        {:single_curly_brackets,
         dgettext(
           "dashboard_integrations",
           "Use double curly brackets: {{meeting_id}} not {meeting_id}"
         )}

      Regex.match?(~r/\[\[meeting_id\]\]/i, url) ->
        {:square_brackets,
         dgettext(
           "dashboard_integrations",
           "Use curly brackets: {{meeting_id}} not [[meeting_id]]"
         )}

      Regex.match?(~r/\(\(meeting_id\)\)/i, url) ->
        {:parentheses,
         dgettext(
           "dashboard_integrations",
           "Use curly brackets: {{meeting_id}} not ((meeting_id))"
         )}

      Regex.match?(~r/<+meeting_id>+/i, url) ->
        {:angle_brackets,
         dgettext("dashboard_integrations", "Use curly brackets: {{meeting_id}} not <meeting_id>")}

      true ->
        {:wrong_bracket_type,
         dgettext("dashboard_integrations", "Use double curly brackets: {{meeting_id}}")}
    end
  end

  # Variable name issues (hyphen, missing underscore - not case, that's handled separately)
  defp variable_name_issue?(url) do
    Regex.match?(~r/\{\{meeting-id\}\}|\{\{meetingid\}\}/i, url)
  end

  defp variable_name_issue_message(url) do
    cond do
      Regex.match?(~r/\{\{meeting-id\}\}/i, url) ->
        {:hyphen_instead_of_underscore,
         dgettext(
           "dashboard_integrations",
           "Use underscore not hyphen: {{meeting_id}} not {{meeting-id}}"
         )}

      Regex.match?(~r/\{\{meetingid\}\}/i, url) ->
        {:missing_underscore,
         dgettext(
           "dashboard_integrations",
           "Missing underscore: {{meeting_id}} not {{meetingid}}"
         )}

      true ->
        {:variable_name_error,
         dgettext("dashboard_integrations", "Variable name should be: {{meeting_id}}")}
    end
  end

  # A double-brace token that is not a misspelt meeting id
  defp unknown_variable?(url) do
    Regex.match?(~r/\{\{(?![^{}]*meeting[\s_-]*id)[^{}]*\}\}/i, url)
  end
end
