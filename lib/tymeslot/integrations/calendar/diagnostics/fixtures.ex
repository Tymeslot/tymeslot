defmodule Tymeslot.Integrations.Calendar.Diagnostics.Fixtures do
  @moduledoc """
  Writes no application path makes, for `mix calendar_audit` to plant the
  states it then checks Tymeslot reads or recovers from: provider events in
  shapes the booking writers never produce, a CalDAV write under an ETag the
  caller chooses, and a sync cursor the provider will refuse.

  `Diagnostics` holds the reads and the ordinary writes; this module holds
  the ones that would be a mistake anywhere else, kept apart so that reaching
  for one from application code reads as that mistake.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.ConditionalWrite
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Providers.{CaldavCommon, ProviderAdapter}

  @type integration :: CalendarIntegrationSchema.t()

  @doc """
  Creates `body`, a Graph or Google event body sent as it is, in the
  integration's booking calendar, and answers the event id the provider
  assigned. For the fields the booking writers have no input for: Graph's
  `showAs` beyond free/tentative/busy, Google's `eventType`.
  """
  @spec put_raw_provider_event(integration(), map()) :: {:ok, String.t()} | {:error, term()}
  def put_raw_provider_event(%CalendarIntegrationSchema{provider: "outlook"} = integration, body) do
    with {:ok, calendar_id} <- booking_calendar(integration, nil),
         {:ok, %{"id" => id}} <-
           two_tuple(OutlookCalendarAPI.insert_event(integration, calendar_id, body)) do
      {:ok, id}
    end
  end

  def put_raw_provider_event(%CalendarIntegrationSchema{provider: "google"} = integration, body) do
    with {:ok, calendar_id} <- booking_calendar(integration, "primary"),
         {:ok, %{id: id}} <-
           two_tuple(GoogleCalendarAPI.insert_event(integration, calendar_id, body)) do
      {:ok, id}
    end
  end

  def put_raw_provider_event(_integration, _body), do: {:error, :unsupported_provider}

  @doc """
  Reads the CalDAV event `uid` from the integration's primary calendar, with
  the ETag the server sent it under.
  """
  @spec fetch_caldav_document(integration(), String.t()) ::
          {:ok, String.t(), String.t() | nil} | {:error, term()}
  def fetch_caldav_document(%CalendarIntegrationSchema{} = integration, uid) do
    with {:ok, client, url} <- caldav_event(integration, uid) do
      ConditionalWrite.fetch_document(client, url, ConditionalWrite.with_deadline([]))
    end
  end

  @doc """
  PUTs `ical` over the CalDAV event `uid` under `If-Match: etag`, and fails
  rather than resolves a rejected precondition: `{:error,
  :precondition_failed}` is what a stale ETag must answer.
  """
  @spec put_caldav_document(integration(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def put_caldav_document(%CalendarIntegrationSchema{} = integration, uid, ical, etag) do
    with {:ok, client, url} <- caldav_event(integration, uid) do
      ConditionalWrite.put(client, url, ical, etag, :fail, ConditionalWrite.with_deadline([]))
    end
  end

  @doc """
  Replaces the integration's stored sync cursor (Graph's delta link, Google's
  sync token) with `cursor`, and answers the one it replaced so the caller can
  put it back.
  """
  @spec replace_sync_cursor(integration(), String.t() | nil) ::
          {:ok, String.t() | nil} | {:error, term()}
  def replace_sync_cursor(%CalendarIntegrationSchema{provider: "outlook", id: id}, cursor) do
    with {:ok, stored} <- stored(id),
         {:ok, _updated} <- CalendarIntegrationWebhookQueries.update_delta_link(stored, cursor) do
      {:ok, stored.graph_delta_link}
    end
  end

  def replace_sync_cursor(%CalendarIntegrationSchema{provider: "google", id: id}, cursor) do
    with {:ok, stored} <- stored(id),
         {:ok, _updated} <-
           CalendarIntegrationQueries.update_sync_state(stored, %{google_sync_token: cursor}) do
      {:ok, stored.google_sync_token}
    end
  end

  def replace_sync_cursor(_integration, _cursor), do: {:error, :no_sync_cursor}

  @doc "The integration's stored sync cursor, as `replace_sync_cursor/2` writes it."
  @spec sync_cursor(integration()) :: {:ok, String.t() | nil} | {:error, term()}
  def sync_cursor(%CalendarIntegrationSchema{provider: provider, id: id})
      when provider in ["outlook", "google"] do
    with {:ok, stored} <- stored(id) do
      {:ok,
       if(provider == "outlook", do: stored.graph_delta_link, else: stored.google_sync_token)}
    end
  end

  def sync_cursor(_integration), do: {:error, :no_sync_cursor}

  # The stored row, read fresh: the cursor a sync last wrote, not the one the
  # caller's struct was loaded with.
  defp stored(id), do: two_tuple(CalendarIntegrationQueries.get(id))

  # The provider APIs and `get/1` answer some failures with a detail beside
  # the reason; this module's callers take one error term.
  defp two_tuple({:error, reason, detail}), do: {:error, {reason, detail}}
  defp two_tuple(result), do: result

  defp booking_calendar(%{default_booking_calendar_id: id}, _fallback)
       when is_binary(id) and id != "",
       do: {:ok, id}

  defp booking_calendar(_integration, nil), do: {:error, :no_booking_calendar}
  defp booking_calendar(_integration, fallback), do: {:ok, fallback}

  defp caldav_event(integration, uid) do
    with {:ok, %{client: client}} <- ProviderAdapter.new_client_from_integration(integration) do
      case CaldavCommon.primary_event_url(client, uid) do
        nil -> {:error, :no_calendar}
        url -> {:ok, client, url}
      end
    end
  end
end
