defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPI do
  @moduledoc """
  Google Calendar API client using direct HTTP calls.
  Handles authentication, token refresh, and calendar CRUD operations.
  """

  @behaviour Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.Google.ApiStatus
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour
  alias Tymeslot.Integrations.Calendar.Google.EventListing
  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Integrations.Calendar.Google.PushChannel
  alias Tymeslot.Integrations.Calendar.HTTP
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Shared.ApiResponse
  alias Tymeslot.Integrations.Common.OAuth.ErrorParser
  alias Tymeslot.Integrations.Common.OAuth.Token, as: OAuthToken
  alias Tymeslot.Integrations.Common.OAuth.TokenExchange
  alias Tymeslot.Integrations.Google.Endpoints

  import ErrorParser, only: [is_oauth_error_status: 1]

  @base_url "https://www.googleapis.com/calendar/v3"

  @type calendar_event :: %{
          id: String.t(),
          summary: String.t() | nil,
          description: String.t() | nil,
          location: String.t() | nil,
          start: map(),
          end: map(),
          status: String.t() | nil
        }

  @type api_error :: CalendarAPIBehaviour.api_error()

  @doc """
  Lists all accessible calendars for the authenticated user.
  """
  @impl CalendarAPIBehaviour
  @spec list_calendars(CalendarIntegrationSchema.t()) :: {:ok, [map()]} | api_error()
  def list_calendars(%CalendarIntegrationSchema{} = integration) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <- make_request(:get, "/users/me/calendarList", token) do
        {:ok, response["items"] || []}
      end
    end)
  end

  @doc """
  Lists events for a specific calendar within a date range, every page of
  it: `{:ok, events}` is the whole window, never a truncated first page, so
  the sync may take an event's absence from it as the event's deletion.
  """
  @impl CalendarAPIBehaviour
  @spec list_events(CalendarIntegrationSchema.t(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [calendar_event()]} | api_error()
  def list_events(%CalendarIntegrationSchema{} = integration, calendar_id, start_time, end_time) do
    params = %{
      "timeMin" => DateTime.to_iso8601(start_time),
      "timeMax" => DateTime.to_iso8601(end_time),
      "singleEvents" => "true",
      "orderBy" => "startTime"
    }

    # Outside the circuit breaker, as this read has always been: its live
    # callers (availability, the connection test) handle no
    # `{:error, :circuit_open}`.
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, %{events: events}} <-
             EventListing.fetch_all(token, calendar_id, params, breaker: false),
           do: {:ok, events}
    end)
  end

  @doc """
  Lists events for the primary calendar within a date range.
  """
  @impl CalendarAPIBehaviour
  @spec list_primary_events(CalendarIntegrationSchema.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [calendar_event()]} | api_error()
  def list_primary_events(%CalendarIntegrationSchema{} = integration, start_time, end_time) do
    list_events(integration, "primary", start_time, end_time)
  end

  @doc """
  Creates a new event in the specified calendar.

  When `conferenceData` was attached to the request and the initial response
  carries a pending `createRequest` (Google's async Meet provisioning), a
  single follow-up GET is issued to retrieve the populated `entryPoints`. If
  the second response is still pending the original response is returned as-is
  and the caller handles the missing URL.
  """
  @impl CalendarAPIBehaviour
  @spec create_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def create_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_data) do
    body =
      event_data
      |> EventMapper.format_new_event_data()
      |> EventMapper.add_tymeslot_fingerprint()

    params = write_params(event_data)
    conference_requested? = EventMapper.requires_conference_data_version?(event_data)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, created} <-
             make_request_with_body(:post, "/calendars/#{calendar_id}/events", token, body,
               params: params
             ) do
        if conference_requested? and conference_pending?(created) do
          event_id = created["id"]
          fetch_event_once(token, calendar_id, event_id, created)
        else
          {:ok, created}
        end
      end
    end)
  end

  # Issues a single GET for the event and returns the fresh response when
  # `entryPoints` are now populated, otherwise falls back to `fallback`.
  defp fetch_event_once(token, calendar_id, event_id, fallback) do
    case make_request(:get, "/calendars/#{URI.encode(calendar_id)}/events/#{event_id}", token) do
      {:ok, refreshed} -> {:ok, refreshed}
      {:error, _type, _msg} -> {:ok, fallback}
    end
  end

  # Returns true when the Google response signals that Meet provisioning is
  # still in-flight: `createRequest` present AND `entryPoints` absent/empty.
  defp conference_pending?(event) do
    create_request = get_in(event, ["conferenceData", "createRequest"])
    entry_points = get_in(event, ["conferenceData", "entryPoints"])

    not is_nil(create_request) and
      (is_nil(entry_points) or entry_points == [] or
         get_in(create_request, ["status", "statusCode"]) == "pending")
  end

  # Conference data is ignored on a write without `conferenceDataVersion=1`,
  # which is what keeps an ordinary edit's `PUT` from touching the event's
  # conference. Only a write that carries a conference change sends it.
  defp write_params(event_data) do
    base = %{"sendUpdates" => "none"}

    if EventMapper.requires_conference_data_version?(event_data) do
      Map.put(base, "conferenceDataVersion", "1")
    else
      base
    end
  end

  @doc """
  Updates an existing event in the specified calendar.

  The event's conference is left as it is unless `event_data` carries a
  conference change (`:conference_data`): a `createRequest` gives the event a
  new Meet conference, and `ConferenceData.remove/0` takes it off. Either is
  sent with `conferenceDataVersion=1`.
  """
  @impl CalendarAPIBehaviour
  @spec update_event(CalendarIntegrationSchema.t(), String.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def update_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id, event_data) do
    body =
      event_data
      |> EventMapper.format_event_data()
      |> EventMapper.add_tymeslot_fingerprint()

    google_event_id = EventMapper.uuid_to_google_event_id(event_id)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request_with_body(
        :put,
        "/calendars/#{calendar_id}/events/#{google_event_id}",
        token,
        body,
        params: write_params(event_data)
      )
    end)
  end

  @doc """
  Patches only the event's `colorId` — used by the colour write-back path so
  recurrence/attendees/reminders/conference data already on the event are
  never touched. Uses `PATCH` (not `PUT`), which Google only applies to the
  fields present in the request body.

  Returns `:ok` without making a request when `colour` does not map to a
  known Google `colorId` (see `EventColour.google_color_id/1`) — nothing to
  patch, matching the outbound-mapper convention of leaving Google's default
  colour untouched for unrecognised values.
  """
  @impl CalendarAPIBehaviour
  @spec patch_event_colour(CalendarIntegrationSchema.t(), String.t(), String.t(), String.t()) ::
          {:ok, calendar_event()} | :ok | api_error()
  def patch_event_colour(
        %CalendarIntegrationSchema{} = integration,
        calendar_id,
        event_id,
        colour
      ) do
    case EventColour.google_color_id(colour) do
      nil ->
        :ok

      color_id ->
        google_event_id = EventMapper.uuid_to_google_event_id(event_id)

        AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
          make_request_with_body(
            :patch,
            "/calendars/#{calendar_id}/events/#{google_event_id}",
            token,
            %{"colorId" => color_id},
            params: %{"sendUpdates" => "none"}
          )
        end)
    end
  end

  @doc """
  Patches `event_id` with `body`, a Google event body carrying only the keys
  to change: Google applies a `PATCH` to the fields present and leaves every
  other one as it is, where `update_event/4`'s `PUT` replaces the event.
  Google's own notifications are suppressed, as on every write here.
  """
  @impl CalendarAPIBehaviour
  @spec patch_event(CalendarIntegrationSchema.t(), String.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def patch_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id, body) do
    google_event_id = EventMapper.uuid_to_google_event_id(event_id)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request_with_body(
        :patch,
        "/calendars/#{URI.encode(calendar_id)}/events/#{google_event_id}",
        token,
        body,
        params: %{"sendUpdates" => "none"}
      )
    end)
  end

  @doc """
  Inserts `body`, a Google event body written as it is, into `calendar_id`.
  Unlike `create_event/3`, nothing is mapped or added. A body carrying
  `conferenceData` is sent with `conferenceDataVersion=1`, which copies the
  conference it names (and would make a new one only for a `createRequest`).
  Google's own notifications are suppressed, as on every write here.
  """
  @impl CalendarAPIBehaviour
  @spec insert_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def insert_event(%CalendarIntegrationSchema{} = integration, calendar_id, body) do
    params =
      if Map.has_key?(body, "conferenceData"),
        do: %{"sendUpdates" => "none", "conferenceDataVersion" => "1"},
        else: %{"sendUpdates" => "none"}

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request_with_body(:post, "/calendars/#{URI.encode(calendar_id)}/events", token, body,
        params: params
      )
    end)
  end

  @doc """
  Fetches one event of the specified calendar by its Google event id.

  A deleted event answers 404, or 410 once Google has purged it; one deleted
  recently can still come back with `"status" => "cancelled"`.
  """
  @impl CalendarAPIBehaviour
  @spec get_event(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          {:ok, calendar_event()} | api_error()
  def get_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      google_event_id = EventMapper.uuid_to_google_event_id(event_id)
      make_request(:get, "/calendars/#{URI.encode(calendar_id)}/events/#{google_event_id}", token)
    end)
  end

  @doc """
  Lists every instance of the recurring event `master_id` in `calendar_id`
  within a date range (`events.instances`), every page of it, so the sync
  may take an instance's absence from it as the instance's removal. Only
  instances that exist are returned: cancelled ones are left out.
  """
  @impl CalendarAPIBehaviour
  @spec list_instances(
          CalendarIntegrationSchema.t(),
          String.t(),
          String.t(),
          DateTime.t(),
          DateTime.t()
        ) :: {:ok, [calendar_event()]} | {:error, :circuit_open} | api_error()
  def list_instances(integration, calendar_id, master_id, start_time, end_time) do
    params = %{
      "timeMin" => DateTime.to_iso8601(start_time),
      "timeMax" => DateTime.to_iso8601(end_time)
    }

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, %{events: events}} <-
             EventListing.fetch_all(token, calendar_id, params, instances_of: master_id),
           do: {:ok, events}
    end)
  end

  @doc """
  Lists the events that make up the recurring event `ical_uid` in
  `calendar_id`, unexpanded: its master, the occurrences edited on their
  own, and, with `status` `cancelled`, those cancelled on their own. Each
  occurrence names the master in `recurringEventId`.
  """
  @impl CalendarAPIBehaviour
  @spec list_series_events(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          {:ok, [calendar_event()]} | api_error()
  def list_series_events(%CalendarIntegrationSchema{} = integration, calendar_id, ical_uid) do
    params = %{"iCalUID" => ical_uid, "showDeleted" => "true"}

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, %{events: events}} <- EventListing.fetch_all(token, calendar_id, params),
           do: {:ok, events}
    end)
  end

  @doc """
  Deletes an event from the specified calendar.
  """
  @impl CalendarAPIBehaviour
  @spec delete_event(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          :ok | api_error()
  def delete_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      google_event_id = EventMapper.uuid_to_google_event_id(event_id)

      case make_request(:delete, "/calendars/#{calendar_id}/events/#{google_event_id}", token) do
        {:ok, _response} -> :ok
        {:error, :gone, _message} -> :ok
        error -> error
      end
    end)
  end

  @doc """
  Moves the event `event_id` from `calendar_id` to `destination_calendar_id`
  of the same account (`events.move`). The event keeps its id and
  `iCalUID`, and a recurring event's master takes every instance with it,
  instances edited on their own and exceptions included, and its
  conference. Answers the event as it now is on the destination. Google's
  own notifications are suppressed, as on every write here.
  """
  @impl CalendarAPIBehaviour
  @spec move_event(CalendarIntegrationSchema.t(), String.t(), String.t(), String.t()) ::
          {:ok, calendar_event()} | api_error()
  def move_event(
        %CalendarIntegrationSchema{} = integration,
        calendar_id,
        event_id,
        destination_calendar_id
      ) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      google_event_id = EventMapper.uuid_to_google_event_id(event_id)

      make_request(
        :post,
        "/calendars/#{URI.encode(calendar_id)}/events/#{google_event_id}/move",
        token,
        %{"destination" => destination_calendar_id, "sendUpdates" => "none"}
      )
    end)
  end

  @doc """
  Fetches the incremental event list for the integration using the stored sync token.

  Returns `{:ok, %{events: [...], next_sync_token: token}}` on success,
  `{:error, :gone, message}` when the sync token has expired (HTTP 410),
  or another error tuple on failure.
  """
  @impl CalendarAPIBehaviour
  @spec list_events_incremental(CalendarIntegrationSchema.t()) ::
          {:ok, %{events: [map()], next_sync_token: String.t() | nil}}
          | {:error, :gone, String.t()}
          | api_error()
  def list_events_incremental(%CalendarIntegrationSchema{google_sync_token: nil}) do
    {:error, :no_sync_token}
  end

  def list_events_incremental(%CalendarIntegrationSchema{} = integration) do
    calendar_id = integration.default_booking_calendar_id || "primary"
    sync_token = integration.google_sync_token

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      # `syncToken` and `pageToken` travel together through every page of a
      # delta listing. That is what Google's own incremental-sync sample does
      # and what this code has always done; it looks redundant and is not.
      # `singleEvents` repeats the bootstrap's, as a token requires: without
      # it a series changed since the bootstrap arrives as its unexpanded
      # master and is cached as one event in place of its occurrences.
      EventListing.fetch_all(
        token,
        calendar_id,
        %{"syncToken" => sync_token, "singleEvents" => "true"}
      )
    end)
  end

  @doc """
  Performs an initial (full) sync for a fresh integration or after sync-token
  expiry. Paginates `GET /events` with no sync token, returning every event in
  the configured sync window together with the `nextSyncToken` that represents
  the state after the listing — the exact value callers should persist so that
  subsequent `list_events_incremental/1` calls return deltas only.

  This is the one path that always works on self-hosted deployments: it has no
  dependency on `:webhook_base_url` and no dependency on an existing sync token.
  """
  @impl CalendarAPIBehaviour
  @spec bootstrap_sync(CalendarIntegrationSchema.t()) ::
          {:ok, %{events: [map()], next_sync_token: String.t() | nil}} | api_error()
  def bootstrap_sync(%CalendarIntegrationSchema{} = integration) do
    calendar_id = integration.default_booking_calendar_id || "primary"
    now = DateTime.utc_now()
    start_time = DateTime.add(now, -ProviderConfig.sync_window_past_days(), :day)
    end_time = DateTime.add(now, ProviderConfig.sync_window_future_days(), :day)

    base = %{
      "timeMin" => DateTime.to_iso8601(start_time),
      "timeMax" => DateTime.to_iso8601(end_time),
      "singleEvents" => "true"
    }

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      EventListing.fetch_all(token, calendar_id, base)
    end)
  end

  @doc """
  Refreshes the access token using the refresh token.
  """
  @impl CalendarAPIBehaviour
  @spec refresh_token(CalendarIntegrationSchema.t()) ::
          {:ok, {String.t(), String.t(), DateTime.t()}} | api_error()
  def refresh_token(%CalendarIntegrationSchema{} = integration) do
    integration = CalendarIntegrationSchema.decrypt_oauth_tokens(integration)

    with {:ok, client_id} <- google_client_id(),
         {:ok, client_secret} <- google_client_secret() do
      body = %{
        "grant_type" => "refresh_token",
        "refresh_token" => integration.refresh_token,
        "client_id" => client_id,
        "client_secret" => client_secret
      }

      case TokenExchange.refresh_access_token(Endpoints.token_url(), body,
             fallback_refresh_token: integration.refresh_token,
             log_context: [
               integration_id: integration.id,
               user_id: integration.user_id,
               provider: :google
             ]
           ) do
        {:ok, %{access_token: access_token, refresh_token: new_refresh, expires_at: expires_at}} ->
          {:ok, {access_token, new_refresh, expires_at}}

        {:error, {:http_error, status, body}} when is_oauth_error_status(status) ->
          {:error, :unauthorized, ErrorParser.build_message("Token refresh failed", status, body)}

        {:error, {:http_error, status, _body}} ->
          {:error, :network_error, "HTTP #{status}"}

        {:error, {:network_error, reason}} ->
          {:error, :network_error, "Network error: #{inspect(reason)}"}
      end
    else
      {:error, :misconfigured} ->
        {:error, :authentication_error, "Google OAuth credentials not configured"}
    end
  end

  @doc """
  Validates if the current token is still valid (not expired).
  """
  @impl CalendarAPIBehaviour
  @spec token_valid?(CalendarIntegrationSchema.t()) :: boolean()
  def token_valid?(%CalendarIntegrationSchema{} = integration) do
    OAuthToken.valid?(integration, 300)
  end

  @doc """
  Registers a Google Calendar push notification channel for the integration.

  Delegates to `Tymeslot.Integrations.Calendar.Google.PushChannel`.
  """
  @impl CalendarAPIBehaviour
  @spec register_push_channel(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :webhook_base_url_not_configured}
          | {:error, :circuit_open}
          | api_error()
  def register_push_channel(%CalendarIntegrationSchema{} = integration) do
    PushChannel.register_push_channel(integration)
  end

  # --- HTTP plumbing (used by sibling modules) ---

  @doc false
  @spec make_request(atom(), String.t(), String.t(), map()) ::
          {:ok, map()} | api_error()
  def make_request(method, path, token, params \\ %{}) do
    HTTP.request(method, @base_url, path, token,
      params: params,
      response_handler: &handle_http_response(&1, path)
    )
  end

  @doc false
  @spec make_request_with_body(atom(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | api_error()
  def make_request_with_body(method, path, token, body, opts \\ []) do
    HTTP.request_with_body(
      method,
      @base_url,
      path,
      token,
      body,
      Keyword.merge([response_handler: &handle_http_response(&1, path)], opts)
    )
  end

  # --- HTTP response handling ---

  defp handle_http_response(response, path) do
    ApiResponse.handle(response, path, label: "Google Calendar", custom: &ApiStatus.classify/1)
  end

  # --- Config helpers ---

  defp google_client_id do
    case Application.get_env(:tymeslot, :google_oauth)[:client_id] ||
           System.get_env("GOOGLE_CLIENT_ID") do
      nil -> {:error, :misconfigured}
      value -> {:ok, value}
    end
  end

  defp google_client_secret do
    case Application.get_env(:tymeslot, :google_oauth)[:client_secret] ||
           System.get_env("GOOGLE_CLIENT_SECRET") do
      nil -> {:error, :misconfigured}
      value -> {:ok, value}
    end
  end
end
