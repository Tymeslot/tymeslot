defmodule Tymeslot.Integrations.Calendar.Outlook.CalendarAPI do
  @moduledoc """
  Microsoft Graph API client for Outlook Calendar using direct HTTP calls.
  Handles authentication, token refresh, and calendar operations.
  """

  @behaviour Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour

  require Logger

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Retry
  alias Tymeslot.Integrations.Calendar.{EventTimeFormatter, HTTP}
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPIBehaviour
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Common.OAuth.Token, as: OAuthToken
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Shared.OAuth.TokenFlow

  @base_url "https://graph.microsoft.com/v1.0"
  @token_url "https://login.microsoftonline.com/common/oauth2/v2.0/token"

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
  @spec create_event(CalendarIntegrationSchema.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def create_event(%CalendarIntegrationSchema{} = integration, event_data) do
    body = format_event_data(event_data)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <- make_request_with_body(:post, "/me/events", token, body) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Creates a new event in a specific calendar.
  """
  @spec create_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def create_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_data) do
    body = format_event_data(event_data)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request_with_body(:post, "/me/calendars/#{calendar_id}/events", token, body) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Updates an existing event in the primary calendar.
  """
  @spec update_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def update_event(%CalendarIntegrationSchema{} = integration, event_id, event_data) do
    body = format_event_data(event_data)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request_with_body(:patch, "/me/events/#{event_id}", token, body) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Updates an existing event in a specific calendar.
  """
  @spec update_event(CalendarIntegrationSchema.t(), String.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def update_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id, event_data) do
    body = format_event_data(event_data)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <-
             make_request_with_body(
               :patch,
               "/me/calendars/#{calendar_id}/events/#{event_id}",
               token,
               body
             ) do
        {:ok, List.first(convert_to_common_format([response]))}
      end
    end)
  end

  @doc """
  Deletes an event from the primary calendar.
  """
  @spec delete_event(CalendarIntegrationSchema.t(), String.t()) ::
          :ok | api_error()
  def delete_event(%CalendarIntegrationSchema{} = integration, event_id) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, _response} <- make_request(:delete, "/me/events/#{event_id}", token, %{}) do
        :ok
      end
    end)
  end

  @doc """
  Deletes an event from a specific calendar.
  """
  @spec delete_event(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          :ok | api_error()
  def delete_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, _response} <-
             make_request(:delete, "/me/calendars/#{calendar_id}/events/#{event_id}", token, %{}) do
        :ok
      end
    end)
  end

  @doc """
  Refreshes the access token using the refresh token.
  """
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
          expires_at = DateTime.add(DateTime.utc_now(), response["expires_in"], :second)

          {:ok,
           {response["access_token"], response["refresh_token"] || integration.refresh_token,
            expires_at}}

        {:error, {:http_error, 400, body}} ->
          {:error, :unauthorized, "Token refresh failed: #{body}"}

        {:error, {:http_error, status, body}} ->
          {:error, :network_error, "HTTP #{status}: #{body}"}

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
  @spec token_valid?(CalendarIntegrationSchema.t()) :: boolean()
  def token_valid?(%CalendarIntegrationSchema{} = integration) do
    OAuthToken.valid?(integration, 300)
  end

  # Private functions

  defp build_events_query_params(start_time, end_time) do
    %{
      "startDateTime" => DateTime.to_iso8601(start_time),
      "endDateTime" => DateTime.to_iso8601(end_time),
      "$orderby" => "start/dateTime",
      "$top" => "1000",
      "$select" => "id,subject,body,location,start,end,showAs,isCancelled,responseStatus,isAllDay"
    }
  end

  defp list_events_for_path(%CalendarIntegrationSchema{} = integration, path, params) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      with {:ok, response} <- make_request(:get, path, token, params) do
        events = response["value"] || []
        {:ok, convert_to_common_format(events)}
      end
    end)
  end

  defp make_request(method, path, token, params) do
    headers = [
      {"Content-Type", "application/json"},
      {"Prefer", "outlook.timezone=\"UTC\""}
    ]

    HTTP.request(method, @base_url, path, token,
      params: params,
      headers: headers,
      request_fun: &request_with_retry/4,
      response_handler: &handle_response/1
    )
  end

  defp handle_response({:ok, %{status: status, body: body}})
       when status in [200, 201, 204] do
    if body == "", do: {:ok, %{}}, else: {:ok, Jason.decode!(body)}
  end

  defp handle_response({:ok, %{status: 401}}) do
    {:error, :unauthorized, "Token expired or invalid"}
  end

  defp handle_response({:ok, %{status: 403, body: body} = resp}) do
    response = Jason.decode!(body)
    msg = get_in(response, ["error", "message"]) || "Forbidden"
    code = String.downcase(to_string(get_in(response, ["error", "code"]) || ""))

    reason = classify_outlook_403(msg, code)
    retry_after = parse_retry_after(resp)

    handle_403_reason(reason, msg, retry_after)
  end

  defp handle_response({:ok, %{status: 404}}) do
    {:error, :not_found, "Calendar not found"}
  end

  defp handle_response({:ok, %{status: 429}}) do
    {:error, :rate_limited, "Too many requests"}
  end

  defp handle_response({:ok, %{status: status, body: body}}) do
    Logger.error("Outlook Calendar API error",
      status: status,
      body: Redactor.redact_and_truncate(body)
    )

    {:error, :network_error, "HTTP #{status} (see logs for details)"}
  end

  defp handle_response({:error, reason}) do
    {:error, :network_error, "Network error: #{inspect(reason)}"}
  end

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

  defp make_request_with_body(method, path, token, body) do
    HTTP.request_with_body(method, @base_url, path, token, body,
      request_fun: &request_with_retry/4,
      response_handler: &handle_response/1
    )
  end

  defp request_with_retry(method, url, body, headers) do
    Retry.with_backoff(fn ->
      http_client().request(method, url, body, headers, [])
    end)
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, HTTPClient)
  end

  defp format_event_data(event_data) do
    %{
      "subject" => extract_field(event_data, :summary, "summary"),
      "body" => build_event_body(event_data),
      "location" => build_event_location(event_data),
      "start" => build_event_datetime(event_data, :start_time, "start_time"),
      "end" => build_event_datetime(event_data, :end_time, "end_time"),
      "showAs" => "busy"
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp extract_field(event_data, atom_key, string_key) do
    Map.get(event_data, atom_key) || Map.get(event_data, string_key)
  end

  defp build_event_body(event_data) do
    %{
      "contentType" => "Text",
      "content" => extract_field(event_data, :description, "description") || ""
    }
  end

  defp build_event_location(event_data) do
    %{
      "displayName" => extract_field(event_data, :location, "location") || ""
    }
  end

  defp build_event_datetime(event_data, atom_key, string_key) do
    datetime = extract_field(event_data, atom_key, string_key)
    timezone = extract_field(event_data, :timezone, "timezone")

    EventTimeFormatter.format_with_timezone(
      datetime,
      timezone,
      include_when_missing?: true,
      include_timezone_on_error?: true
    )
  end

  defp convert_to_common_format(outlook_events) do
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
