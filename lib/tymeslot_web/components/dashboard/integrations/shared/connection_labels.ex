defmodule TymeslotWeb.Components.Dashboard.Integrations.Shared.ConnectionLabels do
  @moduledoc """
  Content helpers for a calendar or video connection's `IntegrationCard`:
  the reason a connection awaits reconnection, for the card's `notice` (a
  calendar card also gives the last sync failure while its syncs keep
  failing), and the server behind a self-hosted one, for its `summary`. Both
  calendar and video build their cards from these so the two hubs word them
  alike.
  """

  alias Tymeslot.Integrations.HealthCheck
  alias Tymeslot.Integrations.Shared.StoredReason

  @doc "The gettext domains a stored reason is looked up in, as a msgid."
  @spec reason_domains() :: [String.t()]
  defdelegate reason_domains, to: StoredReason, as: :domains

  @doc """
  The reason an integration awaiting reconnection was flagged, for the card's
  `notice`, or `nil` when it is not flagged or no reason was recorded.

  `sync_error` also carries transient sync failures, so it is only shown while
  the flag is set: a reconnection is the one state the owner has to act on.
  """
  @spec reconnect_reason(map()) :: String.t() | nil
  def reconnect_reason(%{needs_reauth: true} = integration), do: stored_reason(integration)

  def reconnect_reason(_integration), do: nil

  @doc """
  The card notice for a calendar connection: why it awaits reconnection, or,
  while its syncs are failing, the last failure recorded on `sync_error`.
  `nil` when there is nothing to tell the owner.

  The failure is shown only once `HealthCheck.attention_status/2` calls the
  connection `:unhealthy` (a streak of failed syncs), not after a single one,
  and a successful sync clears it. Every calendar sync writer stores a fixed
  msgid, so it is translated here like a reconnection reason.
  """
  @spec calendar_notice(map(), map() | nil) :: String.t() | nil
  def calendar_notice(integration, health_state) do
    reconnect_reason(integration) ||
      if HealthCheck.attention_status(integration, health_state) == :unhealthy,
        do: stored_reason(integration)
  end

  defp stored_reason(%{sync_error: reason}) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      trimmed -> translate_reason(trimmed)
    end
  end

  defp stored_reason(_integration), do: nil

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

  @doc """
  A reason stored as an English msgid, translated into the viewer's locale
  (see `Tymeslot.Integrations.Shared.StoredReason`).
  """
  @spec translate_reason(String.t()) :: String.t()
  defdelegate translate_reason(reason), to: StoredReason, as: :translate
end
