defmodule Tymeslot.Emails.Shared.Greeting do
  @moduledoc """
  Builds the salutation line for user-addressed emails.

  Resolves the user's display name from the schema; when no name is set
  (or it is blank), returns a neutral, name-less greeting via a separate
  gettext key so each locale can choose a natural phrasing — English
  "Hi there," vs German "Hallo," — instead of splicing an untranslated
  word into a translated template.

  Never falls back to the user's email address; leaking it into a body
  greeting reads as a bug ("Hi me@example.com,").
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.Sanitise

  @doc """
  Returns the salutation ready to interpolate into an HTML/MJML body.
  The interpolated name is HTML-escaped.
  """
  @spec html(map()) :: String.t()
  def html(user) do
    case display_name(user) do
      nil -> dgettext("emails", "Hi there,")
      name -> dgettext("emails", "Hi %{name},", name: Sanitise.sanitize_for_email(name))
    end
  end

  @doc """
  Returns the salutation ready to interpolate into a plain-text body.
  """
  @spec text(map()) :: String.t()
  def text(user) do
    case display_name(user) do
      nil -> dgettext("emails", "Hi there,")
      name -> dgettext("emails", "Hi %{name},", name: name)
    end
  end

  defp display_name(%{name: name}) when is_binary(name) do
    case String.trim(name) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp display_name(_), do: nil
end
