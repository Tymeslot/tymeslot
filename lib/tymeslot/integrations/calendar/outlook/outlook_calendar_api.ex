defmodule Tymeslot.Integrations.Calendar.Outlook.CalendarAPI do
  @moduledoc """
  Microsoft Graph API client for Outlook Calendar using direct HTTP calls.
  Handles authentication, token refresh, and calendar CRUD operations.
  """

  @behaviour Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.HTTP
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour
  alias Tymeslot.Integrations.Calendar.Outlook.EventMapper
  alias Tymeslot.Integrations.Calendar.Outlook.GraphSubscription
  alias Tymeslot.Integrations.Calendar.Outlook.TymeslotFingerprint
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Shared.ApiResponse
  alias Tymeslot.Integrations.Common.OAuth.Token, as: OAuthToken
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Shared.OAuth.TokenFlow

  @base_url "https://graph.microsoft.com/v1.0"
  @silent_event_headers [
    {"Content-Type", "application/json"},
    {"Prefer", "outlook.calendar-update.disableNotifications"}
  ]
  @token_url "https://login.microsoftonline.com/common/oauth2/v2.0/token"

  # Fields the event-driven sync workers need to normalise a single event.
  @event_sync_select_fields "id,subject,start,end,iCalUId,location,bodyPreview,attendees,recurrence,seriesMasterId,type,isAllDay,showAs"

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
    # Select only necessary fields to avoid API issues
    params = %{
      "$select" =>
        "id,name,canEdit,canShare,canViewPrivateItems,changeKey,color,hexColor,isDefaultCalendar,isRemovable,owner"
    }

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <- make_request(:get, "/me/calendars", token, params) do
        {:ok, response["value"] || []}
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
    params = build_events_query_params(start_time, end_time)
    path = "/me/calendars/#{calendar_id}/calendarView"
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
          {:ok, calendar_event()} | api_error()
  def create_event(%CalendarIntegrationSchema{} = integration, event_data) do
    body =
      event_data
      |> EventMapper.format_event_data()
      |> EventMapper.add_tymeslot_fingerprint()

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request_with_body(:post, "/me/events", token, body,
               headers: @silent_event_headers
             ) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Creates a new event in a specific calendar.
  """
  @impl CalendarAPIBehaviour
  @spec create_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def create_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_data) do
    body =
      event_data
      |> EventMapper.format_event_data()
      |> EventMapper.add_tymeslot_fingerprint()

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request_with_body(:post, "/me/calendars/#{calendar_id}/events", token, body,
               headers: @silent_event_headers
             ) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Updates an existing event in the primary calendar.
  """
  @impl CalendarAPIBehaviour
  @spec update_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def update_event(%CalendarIntegrationSchema{} = integration, event_id, event_data) do
    body =
      event_data
      |> EventMapper.format_event_data()
      |> EventMapper.add_tymeslot_fingerprint()

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request_with_body(:patch, "/me/events/#{event_id}", token, body,
               headers: @silent_event_headers
             ) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Updates an existing event in a specific calendar.
  """
  @impl CalendarAPIBehaviour
  @spec update_event(CalendarIntegrationSchema.t(), String.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def update_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id, event_data) do
    body =
      event_data
      |> EventMapper.format_event_data()
      |> EventMapper.add_tymeslot_fingerprint()

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request_with_body(
               :patch,
               "/me/calendars/#{calendar_id}/events/#{event_id}",
               token,
               body,
               headers: @silent_event_headers
             ) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Deletes an event from the primary calendar.
  """
  @impl CalendarAPIBehaviour
  @spec delete_event(CalendarIntegrationSchema.t(), String.t()) ::
          :ok | api_error()
  def delete_event(%CalendarIntegrationSchema{} = integration, event_id) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      case make_request(:delete, "/me/events/#{event_id}", token, %{}) do
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
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      case make_request(:delete, "/me/calendars/#{calendar_id}/events/#{event_id}", token, %{}) do
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

    current_scope =
      integration.oauth_scope ||
        "https://graph.microsoft.com/Calendars.ReadWrite https://graph.microsoft.com/User.Read offline_access openid profile"

    with {:ok, client_id} <- MicrosoftConfig.fetch_client_id(),
         {:ok, client_secret} <- MicrosoftConfig.fetch_client_secret() do
      body = %{
        "grant_type" => "refresh_token",
        "refresh_token" => integration.refresh_token,
        "client_id" => client_id,
        "client_secret" => client_secret,
        "scope" => current_scope
      }

      case TokenFlow.refresh_token(@token_url, body, provider: :outlook) do
        {:ok, response} ->
          expires_in = response["expires_in"] || 3600
          expires_at = DateTime.add(DateTime.utc_now(), expires_in, :second)

          {:ok,
           {response["access_token"], response["refresh_token"] || integration.refresh_token,
            expires_at}}

        {:error, {:http_error, 400, _body}} ->
          {:error, :unauthorized, "Token refresh failed"}

        {:error, {:http_error, status, _body}} ->
          {:error, :network_error, "HTTP #{status}"}

        {:error, {:network_error, reason}} ->
          {:error, :network_error, "Network error: #{inspect(reason)}"}
      end
    else
      {:error, reason} ->
        {:error, :authentication_error, reason}
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

    make_request(:get, "/me/events/#{event_id}", token, params)
  end

  @doc """
  Fetches one page of a Graph delta query.

  `url` is the full delta or next link exactly as returned by Graph
  (delta links are absolute URLs, not paths). Returns the decoded page map
  (`"value"`, `"@odata.nextLink"`, `"@odata.deltaLink"`), or
  `{:error, :delta_link_expired, message}` when Graph reports 410 Gone and
  the stored link must be re-bootstrapped.
  """
  @spec get_delta_page(String.t(), String.t()) ::
          {:ok, map()} | api_error() | {:error, :delta_link_expired, String.t()}
  def get_delta_page(token, url) do
    uri = URI.parse(url)
    path = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")

    headers = [
      {"Content-Type", "application/json"},
      {"Prefer", "outlook.timezone=\"UTC\""}
    ]

    HTTP.request(:get, "https://graph.microsoft.com", path, token,
      headers: headers,
      response_handler: &handle_delta_response/1
    )
  end

  # HTTP plumbing — used internally and by GraphSubscription

  @doc false
  @spec make_request(atom(), String.t(), String.t(), map()) ::
          {:ok, map()} | api_error()
  def make_request(method, path, token, params) do
    headers = [
      {"Content-Type", "application/json"},
      {"Prefer", "outlook.timezone=\"UTC\", outlook.body-content-type=\"text\""}
    ]

    HTTP.request(method, @base_url, path, token,
      params: params,
      headers: headers,
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

  # Response handling and error classification

  defp handle_response(response, path) do
    ApiResponse.handle(response, path, label: "Outlook Calendar", custom: &graph_status/1)
  end

  defp handle_response(response) do
    ApiResponse.handle(response, label: "Outlook Calendar", custom: &graph_status/1)
  end

  # The statuses Graph answers differently from the shared envelope: a 403
  # carrying its classification in `error.code`, and throttling reported as a
  # bare 429. Both may carry a `Retry-After` the caller should honour.
  defp graph_status({:ok, %{status: 403, body: body} = resp}) do
    ApiResponse.with_error_object(body, fn msg, decoded ->
      code = String.downcase(to_string(get_in(decoded, ["error", "code"]) || ""))
      handle_403_reason(classify_outlook_403(msg, code), msg, parse_retry_after(resp))
    end)
  end

  defp graph_status({:ok, %{status: 429} = resp}) do
    case parse_retry_after(resp) do
      retry_after when is_integer(retry_after) ->
        {:error, :rate_limited, "retry_after:" <> Integer.to_string(retry_after)}

      nil ->
        {:error, :rate_limited, "Too many requests"}
    end
  end

  defp graph_status(_response), do: :default

  # Delta queries share the standard response handling but additionally map
  # 410 Gone — Graph's signal that the delta token is no longer valid and the
  # caller must re-bootstrap.
  defp handle_delta_response({:ok, %{status: 410}}) do
    {:error, :delta_link_expired, "Delta link expired"}
  end

  defp handle_delta_response(response), do: handle_response(response)

  defp classify_outlook_403(msg, code) do
    m = msg |> to_string() |> String.downcase()
    c = code |> to_string() |> String.downcase()

    cond do
      throttled_or_quota?(m, c) -> :rate_limited
      permission_denied?(m, c) -> :unauthorized
      true -> :network_error
    end
  end

  defp throttled_or_quota?(message, code) do
    String.contains?(code, "throttled") or
      String.contains?(message, "throttle") or
      String.contains?(message, "rate") or
      String.contains?(message, "quota")
  end

  defp permission_denied?(message, code) do
    String.contains?(code, "accessdenied") or
      String.contains?(code, "permission") or
      String.contains?(message, "permission") or
      String.contains?(message, "insufficient")
  end

  defp parse_retry_after(resp) do
    headers = Map.get(resp, :headers, %{})

    case Map.get(headers, "retry-after") do
      [value | _rest] ->
        case Integer.parse(value) do
          {n, _remainder} -> n
          _parse_error -> nil
        end

      _no_header ->
        nil
    end
  end

  defp handle_403_reason(:rate_limited, _msg, retry_after) when is_integer(retry_after) do
    {:error, :rate_limited, "retry_after:" <> Integer.to_string(retry_after)}
  end

  defp handle_403_reason(:rate_limited, msg, _retry_after), do: {:error, :rate_limited, msg}
  defp handle_403_reason(:unauthorized, msg, _retry_after), do: {:error, :unauthorized, msg}
  defp handle_403_reason(_other_reason, msg, _retry_after), do: {:error, :network_error, msg}

  # Query helpers

  defp build_events_query_params(start_time, end_time) do
    %{
      "startDateTime" => DateTime.to_iso8601(start_time),
      "endDateTime" => DateTime.to_iso8601(end_time),
      "$orderby" => "start/dateTime",
      "$top" => "1000",
      "$select" =>
        "id,iCalUId,subject,body,location,start,end,showAs,sensitivity,isCancelled,responseStatus,isAllDay,organizer,attendees,reminderMinutesBeforeStart,recurrence,seriesMasterId,originalStartTimeZone,originalEndTimeZone",
      "$expand" =>
        "singleValueExtendedProperties($filter=id eq '#{TymeslotFingerprint.property_id()}')"
    }
  end

  defp list_events_for_path(%CalendarIntegrationSchema{} = integration, path, params) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <- make_request(:get, path, token, params) do
        {:ok, response["value"] || []}
      end
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
end
