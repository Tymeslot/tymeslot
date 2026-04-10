defmodule Tymeslot.Integrations.Calendar.Google.CalendarAPI do
  @moduledoc """
  Google Calendar API client using direct HTTP calls.
  Handles authentication, token refresh, and calendar CRUD operations.
  """

  @behaviour Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour

  require Logger

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPIBehaviour
  alias Tymeslot.Integrations.Calendar.Google.EventMapper
  alias Tymeslot.Integrations.Calendar.Google.PushChannel
  alias Tymeslot.Integrations.Calendar.HTTP
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
      make_request_with_body(:post, "/calendars/#{calendar_id}/events", token, body,
        params: %{"sendUpdates" => "none"}
      )
    end)
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
      response_handler: &handle_http_response/1
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
      Keyword.merge([response_handler: &handle_http_response/1], opts)
    )
  end

  # --- HTTP response handling ---

  defp handle_http_response({:ok, %Req.Response{status: status, body: body}})
       when status in [200, 201, 204] do
    if body == "" do
      {:ok, %{}}
    else
      case Jason.decode(body) do
        {:ok, decoded} -> {:ok, decoded}
        {:error, _decode_error} -> {:error, :network_error, "Malformed JSON response"}
      end
    end
  end

  defp handle_http_response({:ok, %Req.Response{status: 401}}) do
    {:error, :unauthorized, "Token expired or invalid"}
  end

  defp handle_http_response({:ok, %Req.Response{status: 403, body: body}}) do
    case Jason.decode(body) do
      {:ok, response} ->
        error_msg = get_in(response, ["error", "message"]) || "Forbidden"
        reasons = get_in(response, ["error", "errors"]) || []
        classify_403(error_msg, reasons)

      {:error, _decode_error} ->
        {:error, :network_error, "Forbidden (malformed response)"}
    end
  end

  defp handle_http_response({:ok, %Req.Response{status: 404}}) do
    {:error, :not_found, "Calendar not found"}
  end

  defp handle_http_response({:ok, %Req.Response{status: 410}}) do
    {:error, :gone, "Resource no longer available"}
  end

  defp handle_http_response({:ok, %Req.Response{status: status, body: body}}) do
    Logger.error("Google Calendar API error",
      status: status,
      body: Redactor.redact_and_truncate(body)
    )

    {:error, :network_error, "HTTP #{status} (see logs for details)"}
  end

  defp handle_http_response({:error, reason}) do
    {:error, :network_error, "Network error: #{inspect(reason)}"}
  end

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
