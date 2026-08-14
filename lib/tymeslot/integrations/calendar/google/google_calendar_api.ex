defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPI do
  @moduledoc """
  Google Calendar API client using direct HTTP calls.
  Handles authentication, token refresh, and calendar CRUD operations.
  """

  @behaviour Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour
  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Integrations.Calendar.Google.PushChannel
  alias Tymeslot.Integrations.Calendar.HTTP
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Shared.ApiResponse
  alias Tymeslot.Integrations.Common.OAuth.Token, as: OAuthToken
  alias Tymeslot.Integrations.Common.OAuth.TokenExchange

  @base_url "https://www.googleapis.com/calendar/v3"
  @token_url "https://oauth2.googleapis.com/token"

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
  Lists events for a specific calendar within a date range.
  """
  @impl CalendarAPIBehaviour
  @spec list_events(CalendarIntegrationSchema.t(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [calendar_event()]} | api_error()
  def list_events(%CalendarIntegrationSchema{} = integration, calendar_id, start_time, end_time) do
    params = %{
      "timeMin" => DateTime.to_iso8601(start_time),
      "timeMax" => DateTime.to_iso8601(end_time),
      "singleEvents" => "true",
      "orderBy" => "startTime",
      "maxResults" => "2500"
    }

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request(:get, "/calendars/#{URI.encode(calendar_id)}/events", token, params) do
        {:ok, response["items"] || []}
      end
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
      |> EventMapper.format_event_data()
      |> EventMapper.add_tymeslot_fingerprint()

    params = create_event_params(event_data)
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

  defp create_event_params(event_data) do
    base = %{"sendUpdates" => "none"}

    if EventMapper.requires_conference_data_version?(event_data) do
      Map.put(base, "conferenceDataVersion", "1")
    else
      base
    end
  end

  @doc """
  Updates an existing event in the specified calendar.
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
        params: %{"sendUpdates" => "none"}
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
  Fetches one event by its Google event id, returning the raw provider body.

  Built for the series-master lookup: under `singleEvents=true` every event
  Tymeslot caches for a recurring series is an *expanded instance*, whose
  `recurrence` Google does not send and whose cached rule therefore cannot
  describe the series. The master carries the rule, and this is the only way to
  read it — `list_events/4` will never return it while expansion is on.

  `event_id` is sent **verbatim**, deliberately unlike every other event-scoped
  call here. Those take a Tymeslot UID and pass it through
  `EventMapper.uuid_to_google_event_id/1`, which re-hashes anything that is not
  base32hex. A `recurringEventId` is already a Google event id and routinely
  contains characters outside that alphabet (an underscore, in the
  `<master>_<instance-stamp>` form), so mapping one would silently produce a
  32-character digest addressing an event that does not exist — a 404 for an
  event that is plainly there.

  The raw map is returned rather than a normalised `CalendarEvent`: the caller
  wants `"recurrence"`, which is a list holding an RRULE and possibly EXDATEs,
  and the normaliser keeps only the first entry (`map_recurrence_rule/1`).
  Normalising here would discard the exceptions before anything could notice
  them.
  """
  @impl CalendarAPIBehaviour
  @spec get_event(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          {:ok, map()} | api_error()
  def get_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request(:get, "/calendars/#{calendar_id}/events/#{event_id}", token)
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
      result =
        CalendarCircuitBreaker.call(:google, fn ->
          make_request(:get, "/calendars/#{URI.encode(calendar_id)}/events", token, %{
            "syncToken" => sync_token
          })
        end)

      case result do
        {:ok, response} when is_map(response) ->
          {:ok,
           %{
             events: response["items"] || [],
             next_sync_token: response["nextSyncToken"]
           }}

        {:ok, error} ->
          error

        {:error, :circuit_open} = error ->
          error

        other ->
          other
      end
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

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      fetch_bootstrap_page(token, calendar_id, start_time, end_time, nil, [])
    end)
  end

  defp fetch_bootstrap_page(token, calendar_id, start_time, end_time, page_token, acc) do
    base = %{
      "timeMin" => DateTime.to_iso8601(start_time),
      "timeMax" => DateTime.to_iso8601(end_time),
      "singleEvents" => "true",
      "maxResults" => "2500"
    }

    params = maybe_put_page_token(base, page_token)

    result =
      CalendarCircuitBreaker.call(:google, fn ->
        make_request(:get, "/calendars/#{URI.encode(calendar_id)}/events", token, params)
      end)

    case result do
      {:ok, response} when is_map(response) ->
        items = response["items"] || []
        acc = Enum.reverse(items, acc)

        case response["nextPageToken"] do
          nil ->
            {:ok, %{events: Enum.reverse(acc), next_sync_token: response["nextSyncToken"]}}

          next_page ->
            fetch_bootstrap_page(token, calendar_id, start_time, end_time, next_page, acc)
        end

      {:ok, error} ->
        error

      {:error, :circuit_open} = error ->
        error

      other ->
        other
    end
  end

  defp maybe_put_page_token(params, nil), do: params
  defp maybe_put_page_token(params, token), do: Map.put(params, "pageToken", token)

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

      case TokenExchange.refresh_access_token(@token_url, body,
             fallback_refresh_token: integration.refresh_token
           ) do
        {:ok, %{access_token: access_token, refresh_token: new_refresh, expires_at: expires_at}} ->
          {:ok, {access_token, new_refresh, expires_at}}

        {:error, {:http_error, 400, _body}} ->
          {:error, :unauthorized, "Token refresh failed"}

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
    ApiResponse.handle(response, path, label: "Google Calendar", custom: &google_status/1)
  end

  # The statuses Google answers differently from the shared envelope: a 403
  # carrying its classification in `error.errors[].reason`, and a 410 marking a
  # sync token the caller must discard.
  defp google_status({:ok, %Req.Response{status: 403, body: body}}) do
    ApiResponse.with_error_object(body, fn error_msg, decoded ->
      classify_403(error_msg, get_in(decoded, ["error", "errors"]) || [])
    end)
  end

  defp google_status({:ok, %Req.Response{status: 410}}) do
    {:error, :gone, "Resource no longer available"}
  end

  defp google_status(_response), do: :default

  # --- Error classification ---

  defp classify_403(error_msg, reasons) do
    reason_strings =
      reasons
      |> Enum.map(&(&1["reason"] || ""))
      |> Enum.map(&String.downcase/1)

    cond do
      rate_limited?(error_msg, reason_strings) -> {:error, :rate_limited, error_msg}
      unauthorized_forbidden?(error_msg, reason_strings) -> {:error, :unauthorized, error_msg}
      true -> {:error, :network_error, error_msg}
    end
  end

  defp rate_limited?(error_msg, reason_strings) do
    msg = String.downcase(error_msg)

    Enum.any?(reason_strings, &String.contains?(&1, "ratelimit")) or
      String.contains?(msg, "quota") or
      String.contains?(msg, "rate")
  end

  defp unauthorized_forbidden?(error_msg, reason_strings) do
    msg = String.downcase(error_msg)

    String.contains?(msg, "insufficient") or
      String.contains?(msg, "forbidden") or
      Enum.any?(reason_strings, &String.contains?(&1, "insufficientpermissions"))
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
