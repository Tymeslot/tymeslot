defmodule Tymeslot.Integrations.Calendar.Outlook.CalendarAPI do
  @moduledoc """
  Microsoft Graph API client for Outlook Calendar using direct HTTP calls.
  Handles authentication, token refresh, and calendar CRUD operations.
  """

  @behaviour Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.HTTP
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour
  alias Tymeslot.Integrations.Calendar.Outlook.CreatableEvent
  alias Tymeslot.Integrations.Calendar.Outlook.EventMapper
  alias Tymeslot.Integrations.Calendar.Outlook.GraphStatus
  alias Tymeslot.Integrations.Calendar.Outlook.GraphSubscription
  alias Tymeslot.Integrations.Calendar.Outlook.Paging
  alias Tymeslot.Integrations.Calendar.Outlook.TymeslotFingerprint
  alias Tymeslot.Integrations.Calendar.Shared.ApiResponse
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Shared.OAuth.Refresh
  alias Tymeslot.Integrations.Shared.OAuth.TokenEndpoint

  @base_url "https://graph.microsoft.com/v1.0"
  @silent_event_headers [
    {"Content-Type", "application/json"},
    {"Prefer", "outlook.calendar-update.disableNotifications"}
  ]

  # Fields the event-driven sync workers need to normalise a single event.
  # `originalStartTimeZone` is the event's own zone: with `Prefer:
  # outlook.timezone="UTC"` every `start.timeZone` reads UTC.
  @event_sync_select_fields "id,subject,start,end,iCalUId,location,bodyPreview,attendees,recurrence,seriesMasterId,type,originalStart,originalStartTimeZone,isAllDay,showAs"

  @type calendar_event :: %{
          id: String.t(),
          ical_uid: String.t() | nil,
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
    # Select only necessary fields to avoid API issues
    params = %{
      "$select" =>
        "id,name,canEdit,canShare,canViewPrivateItems,changeKey,color,hexColor,isDefaultCalendar,isRemovable,owner"
    }

    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      Paging.list_all(token, "/me/calendars", params)
    end)
  end

  @doc """
  Lists events for a specific calendar within a date range.
  """
  @impl CalendarAPIBehaviour
  @spec list_events(CalendarIntegrationSchema.t(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [calendar_event()]} | api_error()
  def list_events(%CalendarIntegrationSchema{} = integration, calendar_id, start_time, end_time) do
    params = build_events_query_params(start_time, end_time)
    path = calendar_path(calendar_id, "/calendarView")
    list_events_for_path(integration, path, params)
  end

  @doc """
  Lists events for the primary calendar within a date range.
  """
  @impl CalendarAPIBehaviour
  @spec list_primary_events(CalendarIntegrationSchema.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [calendar_event()]} | api_error()
  def list_primary_events(%CalendarIntegrationSchema{} = integration, start_time, end_time) do
    params = build_events_query_params(start_time, end_time)
    path = "/me/calendarView"
    list_events_for_path(integration, path, params)
  end

  @doc """
  Creates a new event in the primary calendar.
  """
  @impl CalendarAPIBehaviour
  @spec create_event(CalendarIntegrationSchema.t(), map()) ::
          {:ok, calendar_event()} | api_error() | CalendarAPIBehaviour.write_refusal()
  def create_event(%CalendarIntegrationSchema{} = integration, event_data) do
    with {:ok, body} <- event_body(event_data) do
      Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
        with {:ok, response} <-
               make_request_with_body(:post, "/me/events", token, body,
                 headers: @silent_event_headers
               ) do
          {:ok, List.first(convert_to_common_format([response]))}
        end
      end)
    end
  end

  @doc """
  Creates a new event in a specific calendar.
  """
  @impl CalendarAPIBehaviour
  @spec create_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error() | CalendarAPIBehaviour.write_refusal()
  def create_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_data) do
    with {:ok, body} <- event_body(event_data) do
      Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
        with {:ok, response} <-
               make_request_with_body(:post, calendar_path(calendar_id, "/events"), token, body,
                 headers: @silent_event_headers
               ) do
          {:ok, List.first(convert_to_common_format([response]))}
        end
      end)
    end
  end

  @doc """
  Updates an existing event in the primary calendar.
  """
  @impl CalendarAPIBehaviour
  @spec update_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error() | CalendarAPIBehaviour.write_refusal()
  def update_event(%CalendarIntegrationSchema{} = integration, event_id, event_data) do
    with {:ok, body} <- event_body(event_data) do
      Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
        with {:ok, response} <-
               make_request_with_body(:patch, event_path(event_id), token, body,
                 headers: @silent_event_headers
               ) do
          {:ok, List.first(convert_to_common_format([response]))}
        end
      end)
    end
  end

  @doc """
  Updates an existing event in a specific calendar.
  """
  @impl CalendarAPIBehaviour
  @spec update_event(CalendarIntegrationSchema.t(), String.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error() | CalendarAPIBehaviour.write_refusal()
  def update_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id, event_data) do
    with {:ok, body} <- event_body(event_data) do
      Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
        with {:ok, response} <-
               make_request_with_body(
                 :patch,
                 calendar_path(calendar_id, "/events/#{HTTP.segment(event_id)}"),
                 token,
                 body,
                 headers: @silent_event_headers
               ) do
          {:ok, List.first(convert_to_common_format([response]))}
        end
      end)
    end
  end

  @doc """
  Patches the event `event_id` of the signed-in user, whichever calendar
  holds it, with `body` exactly as given: a Graph event body carrying only
  the keys to change, which Graph merges into the event. Unlike
  `update_event/3,4`, nothing is added to the body, so a key it leaves out
  keeps its value on the event.
  """
  @impl CalendarAPIBehaviour
  @spec patch_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def patch_event(%CalendarIntegrationSchema{} = integration, event_id, body) do
    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request_with_body(:patch, event_path(event_id), token, body,
               headers: @silent_event_headers
             ) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Creates `body`, a Graph event body written as it is, in the calendar
  `calendar_id`. Unlike `create_event/2,3`, nothing is mapped or added, and
  the event is answered as Graph returned it, with its `id` and `iCalUId`.
  """
  @impl CalendarAPIBehaviour
  @spec insert_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, map()} | api_error()
  def insert_event(%CalendarIntegrationSchema{} = integration, calendar_id, body)
      when is_binary(calendar_id) do
    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request_with_body(:post, calendar_path(calendar_id, "/events"), token, body,
        headers: @silent_event_headers
      )
    end)
  end

  @doc """
  The id of the calendar that holds the event `event_id` of the signed-in
  user, as Graph states it. An answer without one is
  `{:error, :unknown_calendar}`.
  """
  @impl CalendarAPIBehaviour
  @spec get_event_calendar_id(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, String.t()} | {:error, :unknown_calendar} | api_error()
  def get_event_calendar_id(%CalendarIntegrationSchema{} = integration, event_id) do
    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      case make_request(:get, event_path(event_id, "/calendar"), token, %{"$select" => "id"}) do
        {:ok, %{"id" => id}} when is_binary(id) and id != "" -> {:ok, id}
        {:ok, _no_id} -> {:error, :unknown_calendar}
        error -> error
      end
    end)
  end

  @doc """
  Fetches one event of the signed-in user by its Graph event id, whichever
  calendar holds it. A deleted event answers 404; a cancelled meeting can
  still come back with `"isCancelled" => true`.

  Its `body` comes as plain text, unless `body: :stored` asks for it in the
  format it is stored in (HTML, as Outlook writes it), for a copy of the
  event that keeps it as it is.
  """
  @impl CalendarAPIBehaviour
  @spec get_event(CalendarIntegrationSchema.t(), String.t(), keyword()) ::
          {:ok, map()} | api_error()
  def get_event(%CalendarIntegrationSchema{} = integration, event_id, opts \\ []) do
    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request(:get, event_path(event_id), token, %{}, opts)
    end)
  end

  @doc """
  The series master `master_id`, with only what its repeat rule is read
  from: its type, `recurrence` and first start. Through the circuit breaker,
  which counts only failures that say Graph is unwell, so a master that is
  gone (404) does not trip it; an open breaker answers `{:error,
  :circuit_open}`.
  """
  @impl CalendarAPIBehaviour
  @spec get_series_master(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, map()} | api_error() | {:error, term()}
  def get_series_master(%CalendarIntegrationSchema{} = integration, master_id) do
    params = %{"$select" => "id,type,recurrence,start"}

    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      CalendarCircuitBreaker.call(:outlook, fn ->
        make_request(:get, event_path(master_id), token, params)
      end)
    end)
  end

  @doc """
  The occurrences of the series master `master_id` changed on their own:
  `exceptionOccurrences`, the edited ones as events, and
  `cancelledOccurrences`, the occurrence ids of the cancelled ones. Graph
  answers an expanded exception with the `$select`ed fields only, so it
  selects every field a copy takes (`Outlook.CreatableEvent`) and the
  timing, and each `body` comes in the format it is stored in.
  """
  @impl CalendarAPIBehaviour
  @spec get_series_exceptions(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, map()} | api_error()
  def get_series_exceptions(%CalendarIntegrationSchema{} = integration, master_id) do
    params = %{
      "$select" =>
        Enum.join(
          ~w(id cancelledOccurrences exceptionOccurrences originalStart start end attendees) ++
            CreatableEvent.copied_fields(),
          ","
        ),
      "$expand" => "exceptionOccurrences"
    }

    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request(:get, event_path(master_id), token, params, body: :stored)
    end)
  end

  @doc """
  The occurrences of the series master `event_id` between `start_time` and
  `end_time`, as Graph expands them (cancelled ones left out).
  """
  @impl CalendarAPIBehaviour
  @spec list_instances(CalendarIntegrationSchema.t(), String.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [calendar_event()]} | api_error()
  def list_instances(%CalendarIntegrationSchema{} = integration, event_id, start_time, end_time) do
    params = build_events_query_params(start_time, end_time)
    list_events_for_path(integration, event_path(event_id, "/instances"), params)
  end

  @doc """
  Finds the signed-in user's events carrying the iCalendar UID `ical_uid`, in
  every calendar of the mailbox. An event keeps its iCalendar UID when it
  moves to another calendar, where its Graph id changes, so this finds an
  event that `get_event/2` no longer does. Answers `{:ok, []}` only when every
  calendar was asked and none holds it.
  """
  @impl CalendarAPIBehaviour
  @spec find_events_by_ical_uid(CalendarIntegrationSchema.t(), String.t()) ::
          {:ok, [map()]} | api_error()
  def find_events_by_ical_uid(%CalendarIntegrationSchema{} = integration, ical_uid) do
    params = %{
      "$filter" => "iCalUId eq '#{String.replace(ical_uid, "'", "''")}'",
      "$select" => "id,iCalUId,isCancelled"
    }

    with {:ok, calendars} <- list_calendars(integration) do
      Enum.reduce_while(calendars, {:ok, []}, fn %{"id" => calendar_id}, {:ok, found} ->
        case list_events_for_path(integration, calendar_path(calendar_id, "/events"), params) do
          {:ok, events} -> {:cont, {:ok, found ++ events}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Deletes an event from the primary calendar.
  """
  @impl CalendarAPIBehaviour
  @spec delete_event(CalendarIntegrationSchema.t(), String.t()) ::
          :ok | api_error()
  def delete_event(%CalendarIntegrationSchema{} = integration, event_id) do
    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      case make_request(:delete, event_path(event_id), token, %{}) do
        {:ok, _response} -> :ok
        {:error, :not_found, _msg} -> :ok
        error -> error
      end
    end)
  end

  @doc """
  Deletes an event from a specific calendar.
  """
  @impl CalendarAPIBehaviour
  @spec delete_event(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          :ok | api_error()
  def delete_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id) do
    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      case make_request(
             :delete,
             calendar_path(calendar_id, "/events/#{HTTP.segment(event_id)}"),
             token,
             %{}
           ) do
        {:ok, _response} -> :ok
        {:error, :not_found, _msg} -> :ok
        error -> error
      end
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

    ApiResponse.token_refresh(
      TokenEndpoint.refresh_grant(
        MicrosoftConfig,
        integration.refresh_token,
        integration.oauth_scope || MicrosoftConfig.scope(),
        log_context: [
          integration_id: integration.id,
          user_id: integration.user_id,
          provider: :outlook
        ]
      )
    )
  end

  @doc """
  Validates if the current token is still valid (not expired).
  """
  @impl CalendarAPIBehaviour
  @spec token_valid?(CalendarIntegrationSchema.t()) :: boolean()
  def token_valid?(%CalendarIntegrationSchema{} = integration) do
    Refresh.valid?(integration.token_expires_at)
  end

  @doc """
  Registers a Microsoft Graph change notification subscription for the integration,
  fetches an initial delta snapshot, and persists all subscription state to the database.

  Delegates to `Tymeslot.Integrations.Calendar.Outlook.GraphSubscription.register/1`.
  """
  @impl CalendarAPIBehaviour
  @spec register_graph_subscription(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :webhook_base_url_not_configured}
          | {:error, term()}
          | api_error()
  def register_graph_subscription(%CalendarIntegrationSchema{} = integration) do
    GraphSubscription.register(integration)
  end

  @doc """
  Performs the initial delta fetch for the integration, populating the cache
  and seeding `graph_delta_link`. Works without a webhook URL — this is the
  bootstrap path that lets self-hosted deployments sync correctly.

  Delegates to `Tymeslot.Integrations.Calendar.Outlook.GraphSubscription.bootstrap_sync/1`.
  """
  @impl CalendarAPIBehaviour
  @spec bootstrap_sync(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, term()}
          | api_error()
  def bootstrap_sync(%CalendarIntegrationSchema{} = integration) do
    GraphSubscription.bootstrap_sync(integration)
  end

  @doc """
  Fetches a single raw Graph event by its provider event ID.

  Returns the raw decoded JSON map (not converted to common format), with
  the Tymeslot extended property expanded. Takes a bare token because the
  callers (sync workers) manage token refresh and circuit-breaking around
  their own preflight logic.
  """
  @spec get_event_raw(String.t(), String.t()) :: {:ok, map()} | api_error()
  def get_event_raw(token, event_id) do
    params = %{
      "$select" => @event_sync_select_fields,
      "$expand" =>
        "singleValueExtendedProperties($filter=id eq '#{TymeslotFingerprint.property_id()}')"
    }

    make_request(:get, event_path(event_id), token, params)
  end

  # HTTP plumbing — used internally and by GraphSubscription

  # Reads ask for UTC, and for bodies as plain text unless `body: :stored`.
  @doc false
  @spec make_request(atom(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | api_error()
  def make_request(method, path, token, params, opts \\ []) do
    headers = [
      {"Content-Type", "application/json"},
      {"Prefer", read_preference(Keyword.get(opts, :body, :text))}
    ]

    HTTP.request(method, @base_url, path, token,
      params: params,
      headers: headers,
      http_options: Keyword.get(opts, :http_options, []),
      response_handler: &handle_response(&1, path)
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
      Keyword.merge([response_handler: &handle_response(&1, path)], opts)
    )
  end

  # Graph ids are base64 and may carry `/`, `+` or `=`, so each is encoded as
  # a single path segment.
  defp calendar_path(calendar_id, rest), do: "/me/calendars/#{HTTP.segment(calendar_id)}#{rest}"
  defp event_path(event_id, rest \\ ""), do: "/me/events/#{HTTP.segment(event_id)}#{rest}"

  defp read_preference(:text), do: ~s(outlook.timezone="UTC", outlook.body-content-type="text")
  defp read_preference(:stored), do: ~s(outlook.timezone="UTC")

  # Response handling and error classification

  defp handle_response(response, path) do
    ApiResponse.handle(response, path, label: "Outlook Calendar", custom: &GraphStatus.classify/1)
  end

  # Query helpers

  defp build_events_query_params(start_time, end_time) do
    %{
      "startDateTime" => DateTime.to_iso8601(start_time),
      "endDateTime" => DateTime.to_iso8601(end_time),
      "$orderby" => "start/dateTime",
      "$top" => "1000",
      "$select" =>
        "id,iCalUId,subject,body,location,start,end,showAs,sensitivity,isCancelled,responseStatus,isAllDay,organizer,attendees,reminderMinutesBeforeStart,recurrence,seriesMasterId,type,originalStart,originalStartTimeZone,originalEndTimeZone",
      "$expand" =>
        "singleValueExtendedProperties($filter=id eq '#{TymeslotFingerprint.property_id()}')"
    }
  end

  defp list_events_for_path(%CalendarIntegrationSchema{} = integration, path, params) do
    Tokens.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      Paging.list_all(token, path, params)
    end)
  end

  @doc """
  Converts raw Graph API event maps (string keys) to the internal common
  format (atom keys) used by `convert_event/1` in the Provider.
  """
  @spec convert_to_common_format([map()]) :: [map()]
  def convert_to_common_format(outlook_events) do
    Enum.map(outlook_events, fn event ->
      %{
        id: event["id"],
        ical_uid: event["iCalUId"],
        summary: event["subject"],
        description: get_in(event, ["body", "content"]),
        location: get_in(event, ["location", "displayName"]),
        start: event["start"],
        end: event["end"],
        is_all_day: event["isAllDay"] || false,
        status: if(event["isCancelled"], do: "cancelled", else: "confirmed"),
        show_as: event["showAs"],
        response_status: get_in(event, ["responseStatus", "response"])
      }
    end)
  end

  # The Graph body of an event Tymeslot writes, refused before any request
  # when its repeat rule has no Graph pattern.
  defp event_body(event_data) do
    with {:ok, body} <- EventMapper.format_event_data(event_data),
         do: {:ok, EventMapper.add_tymeslot_fingerprint(body)}
  end
end
