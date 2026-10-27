defmodule Tymeslot.Integrations.Shared.StoredReason do
  @moduledoc """
  Translates the reason stored on an integration's `sync_error`.

  The flagging callers (Oban workers, `ReauthHandling`, the video providers)
  persist the reason as its untranslated English msgid, marked with
  `dgettext_noop/2` in one of `domains/0`. Translating at write time would
  bake in the locale of whichever process raised the flag, which is not the
  owner's. Looking the msgid up when it is shown, in the reader's locale, is
  the one place it is translated, for the dashboard card and the reconnect
  email alike; a reason that isn't a known msgid in any of them (a raw
  diagnostic string, or a row flagged before reasons were stored this way)
  comes back unchanged.
  """

  @domains ~w[integrations_calendar integrations_video dashboard_calendar_providers
              dashboard_integrations dashboard_video]

  @doc "The gettext domains a stored reason is looked up in, as a msgid."
  @spec domains() :: [String.t()]
  def domains, do: @domains

  @doc """
  `reason` translated into the current locale from the first of `domains/0`
  that has it, or returned as stored when none does.
  """
  @spec translate(String.t()) :: String.t()
  def translate(reason) do
    Enum.find_value(@domains, reason, fn domain ->
      case Gettext.dgettext(TymeslotWeb.Gettext, domain, reason) do
        ^reason -> nil
        translated -> translated
      end
    end)
  end
end
