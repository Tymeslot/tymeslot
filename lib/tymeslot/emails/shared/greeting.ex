defmodule Tymeslot.Emails.Shared.Greeting do
  @moduledoc """
  Builds the salutation line for user-addressed emails.

  Resolves the recipient's display name through `Profiles.user_display_name/1`
  so the salutation matches what the dashboard calls them: the profile's
  `full_name` first, then the name captured at OAuth signup. The profile has
  to be preloaded on the user for the first rung to apply — the email worker
  handlers load it via `UserQueries.get_user_with_profile/1` — because
  email/password signups never set `user.name` at all, so reading it alone
  greeted every one of them anonymously for the life of the account.

  When no name is set (or it is blank), returns a neutral, name-less greeting
  via a separate gettext key so each locale can choose a natural phrasing —
  English "Hi there," vs German "Hallo," — instead of splicing an untranslated
  word into a translated template.

  Never falls back to the user's email address; leaking it into a body
  greeting reads as a bug ("Hi me@example.com,").
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.Sanitise
  alias Tymeslot.Profiles

  @doc """
  Returns the salutation ready to interpolate into an HTML/MJML body.

  The interpolated name is HTML-escaped here and must not be escaped again by
  the caller: pass the result to `Text.centered_html/2`, never
  `Text.centered_text/2`, or `O'Brien & Sons` arrives as
  `O&#39;Brien &amp; Sons`.
  """
  @spec html(map()) :: String.t()
  def html(user) do
    case Profiles.user_display_name(user) do
      nil -> dgettext("emails", "Hi there,")
      name -> dgettext("emails", "Hi %{name},", name: Sanitise.sanitize_for_email(name))
    end
  end

  @doc """
  Returns the salutation ready to interpolate into a plain-text body.
  """
  @spec text(map()) :: String.t()
  def text(user) do
    case Profiles.user_display_name(user) do
      nil -> dgettext("emails", "Hi there,")
      name -> dgettext("emails", "Hi %{name},", name: name)
    end
  end
end
