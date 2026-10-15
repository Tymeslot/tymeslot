defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionLabels do
  @moduledoc """
  Content helpers for a calendar or video connection's `IntegrationCard`:
  the reason a connection awaits reconnection, for the card's `notice`, and the
  server behind a self-hosted one, for its `summary`. Both calendar and video
  build their cards from these so the two hubs word them alike.
  """

  # The flagging callers (Oban workers, `ReauthHandling`, the video providers)
  # persist the reason as its untranslated English msgid, marked with
  # `dgettext_noop/2` in one of these domains. Translating at write time would
  # bake in the locale of whichever process raised the flag, which is not the
  # owner's. Looking the msgid up here, in the viewer's locale, is the one place
  # it is translated; a reason that isn't a known msgid in any of them (a raw
  # diagnostic string, or a row flagged before reasons were stored this way)
  # comes back unchanged.
  @reason_domains ~w[dashboard_calendar_providers dashboard_integrations dashboard_video]

  @doc """
  The reason an integration awaiting reconnection was flagged, for the card's
  `notice`, or `nil` when it is not flagged or no reason was recorded.

  `sync_error` also carries transient sync failures, so it is only shown while
  the flag is set: a reconnection is the one state the owner has to act on.
  """
  @spec reconnect_reason(map()) :: String.t() | nil
  def reconnect_reason(%{needs_reauth: true, sync_error: reason}) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> translate_reason(trimmed)
    end
  end

  def reconnect_reason(_integration), do: nil

  @doc """
  The server behind a self-hosted integration, rendered for a card's `summary`
  as the owner typed it: host, port and path, without the scheme.

  The port and the path are what tell two instances on one host apart, which is
  the ordinary shape of a staging server or of anything behind a reverse proxy,
  so `http://localhost:8080/nextcloud` reads as `localhost:8080/nextcloud`
  rather than collapsing to `localhost`.

  `userinfo` is dropped explicitly: not every provider rejects a `base_url`
  carrying credentials, so a password typed into the server field must never
  ride along onto the dashboard. Anything that does not parse as an absolute
  URL with a host yields `nil`, so a value stored before this field was
  validated cannot raise here.
  """
  @spec server_label(String.t() | nil) :: String.t() | nil
  def server_label(nil), do: nil

  def server_label(base_url) when is_binary(base_url) do
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host} = uri when is_binary(scheme) and is_binary(host) ->
        %{uri | userinfo: nil}
        |> URI.to_string()
        |> String.replace_prefix(scheme <> "://", "")

      %URI{host: host} when is_binary(host) ->
        host

      %URI{} ->
        nil
    end
  end

  defp translate_reason(reason) do
    Enum.find_value(@reason_domains, reason, fn domain ->
      case Gettext.dgettext(TymeslotWeb.Gettext, domain, reason) do
        ^reason -> nil
        translated -> translated
      end
    end)
  end
end
