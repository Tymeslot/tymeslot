defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPI do
  @moduledoc """
  Google Calendar API client using direct HTTP calls.
  Handles authentication, token refresh, and calendar operations.
  """

  @behaviour Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour

  require Logger

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Infrastructure.Retry
  alias Tymeslot.Integrations.Calendar.{EventTimeFormatter, HTTP}
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
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
             make_request(:get, "/calendars/#{calendar_id}/events", token, params) do
        {:ok, response["items"] || []}
      end
    end)
  end

  @doc """
  Lists events for the primary calendar within a date range.
  """
  @spec list_primary_events(CalendarIntegrationSchema.t(), DateTime.t(), DateTime.t()) ::
          {:ok, [calendar_event()]} | api_error()
  def list_primary_events(%CalendarIntegrationSchema{} = integration, start_time, end_time) do
    list_events(integration, "primary", start_time, end_time)
  end

  @doc """
  Creates a new event in the specified calendar.
  """
  @spec create_event(CalendarIntegrationSchema.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def create_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_data) do
    body = format_event_data(event_data)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request_with_body(:post, "/calendars/#{calendar_id}/events", token, body)
    end)
  end

  @doc """
  Updates an existing event in the specified calendar.
  """
  @spec update_event(CalendarIntegrationSchema.t(), String.t(), String.t(), map()) ::
          {:ok, calendar_event()} | api_error()
  def update_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id, event_data) do
    body = format_event_data(event_data)
    # Convert the event_id to Google Calendar format
    google_event_id = uuid_to_google_event_id(event_id)

    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      make_request_with_body(
        :put,
        "/calendars/#{calendar_id}/events/#{google_event_id}",
        token,
        body
      )
    end)
  end

  @doc """
  Deletes an event from the specified calendar.
  """
  @spec delete_event(CalendarIntegrationSchema.t(), String.t(), String.t()) ::
          :ok | api_error()
  def delete_event(%CalendarIntegrationSchema{} = integration, calendar_id, event_id) do
    AccessToken.with_access_token(integration, &__MODULE__.refresh_token/1, fn token ->
      google_event_id = uuid_to_google_event_id(event_id)

      case make_request(:delete, "/calendars/#{calendar_id}/events/#{google_event_id}", token) do
        {:ok, _response} -> :ok
        {:error, :gone, _message} -> :ok
        error -> error
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

    body = %{
      "grant_type" => "refresh_token",
      "refresh_token" => integration.refresh_token,
      "client_id" => google_client_id(),
      "client_secret" => google_client_secret()
    }

    case TokenExchange.refresh_access_token(@token_url, body,
           fallback_refresh_token: integration.refresh_token
         ) do
      {:ok, %{access_token: access_token, refresh_token: new_refresh, expires_at: expires_at}} ->
        {:ok, {access_token, new_refresh, expires_at}}

      {:error, {:http_error, 400, body}} ->
        {:error, :unauthorized, "Token refresh failed: #{body}"}

      {:error, {:http_error, status, body}} ->
        {:error, :network_error, "HTTP #{status}: #{body}"}

      {:error, {:network_error, reason}} ->
        {:error, :network_error, "Network error: #{inspect(reason)}"}
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

  defp make_request(method, path, token, params \\ %{}) do
    HTTP.request(method, @base_url, path, token,
      params: params,
      request_fun: &request_with_retry/4,
      response_handler: &handle_http_response/1
    )
  end

  defp handle_http_response({:ok, %HTTPoison.Response{status_code: status, body: body}})
       when status in [200, 201, 204] do
    if body == "", do: {:ok, %{}}, else: {:ok, Jason.decode!(body)}
  end

  defp handle_http_response({:ok, %HTTPoison.Response{status_code: 401}}) do
    {:error, :unauthorized, "Token expired or invalid"}
  end

  defp handle_http_response({:ok, %HTTPoison.Response{status_code: 403, body: body}}) do
    response = Jason.decode!(body)
    error_msg = get_in(response, ["error", "message"]) || "Forbidden"
    reasons = get_in(response, ["error", "errors"]) || []

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

  defp handle_http_response({:ok, %HTTPoison.Response{status_code: 404}}) do
    {:error, :not_found, "Calendar not found"}
  end

  defp handle_http_response({:ok, %HTTPoison.Response{status_code: 410}}) do
    {:error, :gone, "Resource no longer available"}
  end

  defp handle_http_response({:ok, %HTTPoison.Response{status_code: status, body: body}}) do
    Logger.error("Google Calendar API error",
      status_code: status,
      body: Redactor.redact_and_truncate(body)
    )

    {:error, :network_error, "HTTP #{status} (see logs for details)"}
  end

  defp handle_http_response({:error, reason}) do
    {:error, :network_error, "Network error: #{inspect(reason)}"}
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

  defp make_request_with_body(method, path, token, body) do
    HTTP.request_with_body(method, @base_url, path, token, body,
      request_fun: &request_with_retry/4,
      response_handler: &handle_http_response/1
    )
  end

  defp request_with_retry(method, url, body, headers) do
    Retry.with_backoff(fn ->
      HTTPClient.request(method, url, body, headers)
    end)
  end

  defp format_event_data(event_data) do
    event_data
    |> extract_event_fields()
    |> add_google_event_id(event_data)
    |> remove_nil_values()
  end

  # Extract the main event fields and format them
  defp extract_event_fields(event_data) do
    timezone = get_field_value(event_data, :timezone)

    %{
      "summary" => get_field_value(event_data, :summary),
      "description" => get_field_value(event_data, :description),
      "location" => get_field_value(event_data, :location),
      "start" =>
        EventTimeFormatter.format_with_timezone(
          get_field_value(event_data, :start_time),
          timezone
        ),
      "end" =>
        EventTimeFormatter.format_with_timezone(
          get_field_value(event_data, :end_time),
          timezone
        ),
      "status" => get_field_value(event_data, :status) || "confirmed"
    }
  end

  # Add Google event ID if uid is provided
  defp add_google_event_id(base_data, event_data) do
    case get_field_value(event_data, :uid) do
      nil -> base_data
      uid -> Map.put(base_data, "id", uuid_to_google_event_id(uid))
    end
  end

  # Helper to get field value from both atom and string keys
  defp get_field_value(map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  # Remove nil values from the map
  defp remove_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  # Convert a UUID to a Google Calendar compatible event ID (base32hex)
  defp uuid_to_google_event_id(uid) when is_binary(uid) do
    # Remove hyphens and convert to lowercase
    uid
    |> String.replace("-", "")
    |> String.downcase()
    # Use first 32 chars to ensure it's valid base32hex
    |> String.slice(0, 32)
  end

  defp google_client_id do
    Application.get_env(:tymeslot, :google_oauth)[:client_id] ||
      System.get_env("GOOGLE_CLIENT_ID") ||
      raise "Google Client ID not configured"
  end

  defp google_client_secret do
    Application.get_env(:tymeslot, :google_oauth)[:client_secret] ||
      System.get_env("GOOGLE_CLIENT_SECRET") ||
      raise "Google Client Secret not configured"
  end
end
