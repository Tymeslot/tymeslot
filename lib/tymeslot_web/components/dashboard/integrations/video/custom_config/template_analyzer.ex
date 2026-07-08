defmodule TymeslotWeb.Components.Dashboard.Integrations.Video.CustomConfig.TemplateAnalyzer do
  @moduledoc """
  Analyzes custom video URL templates for syntax correctness and common mistakes.

  This module validates template variable syntax and detects common errors like:
  - Template in URL fragment (critical - won't work)
  - Mismatched brackets
  - Wrong bracket types
  - Missing brackets
  - Variable name issues (case, underscores, hyphens)
  - Unknown variables

  The only supported template variable is `{{meeting_id}}` (case-sensitive, lowercase only).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video.TemplateConfig

  @type analysis_result ::
          {:ok, :valid_template | :static | :empty, String.t(), String.t()}
          | {:warning, atom(), String.t(), String.t()}

  @doc ~S"""
  Analyzes a URL template string and returns the result type, preview, and message.

  ## Examples

      iex> analyze("https://jitsi.org/{{meeting_id}}")
      {:ok, :valid_template, "https://jitsi.org/a1b2c3d4e5f67890", "Template variable detected: {{meeting_id}}"}

      iex> analyze("https://jitsi.org/{meeting_id}")
      {:warning, :single_brackets, "https://jitsi.org/{meeting_id}", "Did you mean {{meeting_id}}? Found single brackets"}

      iex> analyze("https://meet.example.com/room")
      {:ok, :static, "https://meet.example.com/room", "Static URL - all meetings will use the same room"}

      iex> analyze("https://jitsi.org/room#{{meeting_id}}")
      {:warning, :template_in_fragment, "https://jitsi.org/room#{{meeting_id}}", "Template in fragment (#) won't work..."}
  """
  @spec analyze(String.t() | nil) :: analysis_result()
  def analyze(url) when is_binary(url) and url != "" do
    # Check for template in fragment first (critical issue)
    if template_in_fragment?(url) do
      {:warning, :template_in_fragment, url,
       dgettext(
         "dashboard_integrations",
         "Template in fragment (#) won't work - fragments aren't sent to servers. Use path instead: https://example.com/{{meeting_id}}"
       )}
    else
      case check_valid_template(url) do
        {:ok, result} -> result
        :not_valid -> check_template_errors(url)
      end
    end
  end

  def analyze(_url),
    do: {:ok, :empty, "", dgettext("dashboard_integrations", "Enter a URL to see a preview")}

  # Check for template in fragment position (critical issue)
  defp template_in_fragment?(url) do
    uri = URI.parse(url)
    uri.fragment && String.contains?(uri.fragment, TemplateConfig.template_variable())
  end

  # Valid template check
  defp check_valid_template(url) do
    if valid_template?(url) do
      preview =
        String.replace(url, TemplateConfig.template_variable(), TemplateConfig.sample_hash())

      {:ok,
       {:ok, :valid_template, preview,
        dgettext("dashboard_integrations", "Template variable detected: {{meeting_id}}")}}
    else
      :not_valid
    end
  end

  # Check for template errors - first pass
  defp check_template_errors(url) do
    cond do
      wrong_case?(url) ->
        {:warning, :wrong_case, url,
         dgettext(
           "dashboard_integrations",
           "Use lowercase: {{meeting_id}} not {{MEETING_ID}} or {{Meeting_Id}}"
         )}

      mismatched_brackets?(url) ->
        {type, message} = mismatched_brackets_message(url)
        {:warning, type, url, message}

      missing_brackets?(url) ->
        {type, message} = missing_brackets_message(url)
        {:warning, type, url, message}

      wrong_bracket_type?(url) ->
        {type, message} = wrong_bracket_type_message(url)
        {:warning, type, url, message}

      variable_name_issue?(url) ->
        {type, message} = variable_name_issue_message(url)
        {:warning, type, url, message}

      unknown_variable?(url) ->
        {:warning, :unknown_variable, url,
         dgettext(
           "dashboard_integrations",
           "Unknown template variable. Only {{meeting_id}} is supported"
         )}

      String.contains?(url, "meeting_id") ->
        {:warning, :no_brackets, url,
         dgettext(
           "dashboard_integrations",
           "Found 'meeting_id' without brackets - use {{meeting_id}}"
         )}

      true ->
        {:ok, :static, url,
         dgettext("dashboard_integrations", "Static URL - all meetings will use the same room")}
    end
  end

  # Private helper functions

  # Valid template check - case-sensitive, exact match only
  defp valid_template?(url), do: String.contains?(url, TemplateConfig.template_variable())

  # Check for wrong case (e.g., {{MEETING_ID}}, {{Meeting_Id}})
  # Must have the underscore to be considered a case issue (not missing underscore issue)
  defp wrong_case?(url) do
    # Match double curly brackets with "meeting_id" in any case, but not the correct lowercase
    Regex.match?(~r/\{\{meeting_id\}\}/i, url) and not valid_template?(url)
  end

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
    (Regex.match?(~r/\{\{meeting_id\}?(?!\})/i, url) and not valid_template?(url)) or
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
    String.contains?(url, "{meeting_id}") or
      String.contains?(url, "[[meeting_id]]") or
      String.contains?(url, "((meeting_id))") or
      Regex.match?(~r/<+meeting_id>+/i, url)
  end

  defp wrong_bracket_type_message(url) do
    cond do
      String.contains?(url, "{meeting_id}") ->
        {:single_curly_brackets,
         dgettext(
           "dashboard_integrations",
           "Use double curly brackets: {{meeting_id}} not {meeting_id}"
         )}

      String.contains?(url, "[[meeting_id]]") ->
        {:square_brackets,
         dgettext(
           "dashboard_integrations",
           "Use curly brackets: {{meeting_id}} not [[meeting_id]]"
         )}

      String.contains?(url, "((meeting_id))") ->
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
    # Check for common mistakes with meeting_id spelling (case-insensitive for detection)
    (Regex.match?(~r/\{\{meeting-id\}\}/i, url) or
       Regex.match?(~r/\{\{meetingid\}\}/i, url)) and not valid_template?(url)
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

  # Unknown variable detection
  defp unknown_variable?(url) do
    Regex.match?(~r/\{\{[^}]+\}\}/, url) and not valid_template?(url)
  end
end
