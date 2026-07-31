defmodule Tymeslot.Integrations.Video.Providers.MiroTalkProvider do
  @moduledoc """
  MiroTalk P2P video conferencing provider implementation.

  Provides functions to create meeting rooms, generate join URLs, and manage
  video conferencing sessions for scheduled appointments.
  """

  @behaviour Tymeslot.Integrations.Video.Providers.ProviderBehaviour

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Shared.ProviderConfigHelper
  alias Tymeslot.Integrations.Video.Providers.Capabilities
  alias Tymeslot.Integrations.Video.Providers.MiroTalk.HttpHelpers
  alias Tymeslot.Integrations.Video.Providers.MiroTalk.JoinUrlBuilder
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Security.UrlValidation

  @capabilities Capabilities.new!(
                  recording: false,
                  screen_sharing: true,
                  waiting_room: false,
                  max_participants: 100,
                  dial_in: false,
                  chat: true,
                  breakout_rooms: false
                )

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :mirotalk

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "MiroTalk P2P"

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def connection_test_bucket, do: :mirotalk

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def config_schema do
    %{
      api_key: %{type: :string, required: true, description: "API key for MiroTalk server"},
      base_url: %{type: :string, required: true, description: "Base URL of MiroTalk server"}
    }
  end

  # Structural validation only, in line with every other video provider: the
  # callers that need connectivity (`Video.Connection.probe/3`,
  # `ProviderAdapter.create_meeting_room/2`) invoke `validate_config/1` first and
  # then the function that talks to the server. Reaching the network from here
  # doubled every scheduled health probe against the customer's self-hosted
  # MiroTalk instance, and burned two rate-limiter tokens for one probe.
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def validate_config(config) do
    with :ok <- ProviderConfigHelper.validate_required_fields(config, [:api_key, :base_url]) do
      validate_base_url(Map.get(config, :base_url))
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def capabilities, do: @capabilities

  @doc """
  Tests the connection to the MiroTalk API.

  Pure I/O — the caller (`Tymeslot.Integrations.Video.Connection`) decides
  whether and to whom the test is rate-limited.
  """
  @spec perform_connection_test(%{
          required(:api_key) => String.t(),
          required(:base_url) => String.t()
        }) ::
          {:ok, String.t()} | {:error, term()}
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def perform_connection_test(config) do
    # For MiroTalk, we can test by checking if the API endpoint is reachable
    base_url = Map.get(config, :base_url)
    api_key = Map.get(config, :api_key)

    with :ok <- validate_base_url(base_url) do
      # Proceed with API connection test
      test_api_connection(base_url, api_key)
    end
  end

  defp validate_base_url(nil), do: {:error, "Base URL is required"}
  defp validate_base_url(""), do: {:error, "Base URL cannot be empty"}

  defp validate_base_url(url) do
    UrlValidation.validate_http_url(url, block_private_ips: true)
  end

  defp test_api_connection(base_url, api_key) do
    headers = build_api_headers(api_key)
    options = [timeout: 5_000, ssrf_protect: true]

    # Always try HTTPS first; if it fails due to network/connection, fall back to HTTP
    handle_api_response(
      HttpHelpers.try_https_then_http(base_url, "/api/v1/meeting", fn url ->
        Config.http_client_module().post(url, "", headers, options)
      end)
    )
  end

  defp build_api_headers(api_key) do
    [
      {"authorization", api_key || ""},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
  end

  defp handle_api_response({:ok, response}), do: handle_http_response(response)
  defp handle_api_response({:error, error}), do: handle_http_error(error)

  defp handle_http_response(%Req.Response{status: 200}) do
    {:ok, "Connection successful - API key is valid"}
  end

  defp handle_http_response(%Req.Response{status: 401, body: body}) do
    handle_auth_error(body, "Authentication failed - Please check your API key")
  end

  defp handle_http_response(%Req.Response{status: 403, body: body}) do
    handle_auth_error(body, "Access forbidden - API key may lack required permissions")
  end

  defp handle_http_response(%Req.Response{status: 404}) do
    {:error, "API endpoint not found - Please verify the base URL is correct"}
  end

  defp handle_http_response(%Req.Response{status: 406}) do
    {:error,
     "Not Acceptable - The MiroTalk server rejected the request. Please verify your base URL and API configuration"}
  end

  defp handle_http_response(%Req.Response{status: status, body: body})
       when status >= 500 do
    redacted_body = Redactor.redact_and_truncate(body)

    Logger.error("MiroTalk server error", status: status, body: redacted_body)

    {:error, "MiroTalk server error (status #{status}) - Please try again later"}
  end

  defp handle_http_response(%Req.Response{status: status}) do
    {:error, "Unexpected response (status #{status}) - Please verify your configuration"}
  end

  defp handle_auth_error(body, default_message) do
    if String.contains?(body || "", "Unauthorized") do
      {:error, "Invalid API key - Authentication failed"}
    else
      {:error, default_message}
    end
  end

  defp handle_http_error(exception) when is_exception(exception) do
    case exception do
      # Mint transport errors with specific reasons
      %Mint.TransportError{reason: :nxdomain} ->
        {:error, "Domain not found - Please check the URL"}

      %Mint.TransportError{reason: :econnrefused} ->
        {:error, "Connection refused - Server may be down or URL incorrect"}

      %Mint.TransportError{reason: :timeout} ->
        {:error, "Connection timeout - Server took too long to respond"}

      # Req transport errors (may wrap Mint errors)
      %Req.TransportError{reason: :nxdomain} ->
        {:error, "Domain not found - Please check the URL"}

      %Req.TransportError{reason: :econnrefused} ->
        {:error, "Connection refused - Server may be down or URL incorrect"}

      %Req.TransportError{reason: :timeout} ->
        {:error, "Connection timeout - Server took too long to respond"}

      # Generic fallback with message
      _other ->
        {:error, "Connection failed: #{Exception.message(exception)}"}
    end
  end

  @doc """
  Creates a new MiroTalk meeting room.

  Returns {:ok, meeting_url} on success or {:error, reason} on failure.
  """
  @spec create_meeting_room(%{
          required(:api_key) => String.t(),
          required(:base_url) => String.t()
        }) :: {:ok, map()} | {:error, term()}
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    base_url = Map.get(config, :base_url)

    headers = [
      {"authorization", Map.get(config, :api_key)},
      {"Content-Type", "application/json"}
    ]

    # Try HTTPS first, then HTTP
    case HttpHelpers.try_https_then_http(base_url, "/api/v1/meeting", fn url ->
           Config.http_client_module().post(url, "", headers, ssrf_protect: true)
         end) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, response} ->
            build_room_data(response, config)

          {:error, _decode_error} ->
            Logger.error("Invalid JSON response from MiroTalk API")
            {:error, :invalid_json}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        redacted_body = Redactor.redact_and_truncate(body)

        Logger.error("MiroTalk API error", status: status, body: redacted_body)

        {:error, {:http_error, status, "MiroTalk API error (see logs for details)"}}

      {:error, reason} ->
        Logger.error("Failed to create MiroTalk room", error: Redactor.redact(reason))
        {:error, reason}
    end
  end

  # A 200 response that carries neither a room id nor a meeting URL is not a
  # usable room: persisting it would attach an empty room to the booking. Treat
  # it as a failed creation so the caller can retry or surface the failure.
  defp build_room_data(response, config) when is_map(response) do
    room_id = presence(response["room_id"] || response["meeting"])
    meeting_url = presence(response["meeting_url"] || response["meeting"])

    if is_nil(room_id) and is_nil(meeting_url) do
      Logger.error("MiroTalk API returned no room identifier",
        response_keys: response |> Map.keys() |> Enum.sort()
      )

      {:error, :invalid_room_response}
    else
      {:ok,
       %RoomData{
         room_id: room_id,
         meeting_url: meeting_url,
         provider_data: response,
         provider_config: config
       }}
    end
  end

  defp build_room_data(_response, _config) do
    Logger.error("MiroTalk API returned a non-object JSON body")
    {:error, :invalid_room_response}
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(room_data, participant_name, participant_email, role, meeting_time) do
    room_id = room_data.room_id
    config = room_data.provider_config

    if room_id != "" and participant_name != "" and config do
      # MiroTalk API returns the full meeting URL, but the 'room' parameter
      # for the join API expects only the room name (UUID).
      room_name = extract_room_id(room_id)

      # We prefer using the MiroTalk API to generate the join URL.
      # This ensures the token is generated by the server itself and is guaranteed to be valid.
      case JoinUrlBuilder.create_join_url_via_api(
             config,
             room_name,
             participant_name,
             participant_email,
             role
           ) do
        {:ok, join_url} ->
          {:ok, join_url}

        {:error, reason} ->
          Logger.warning(
            "Failed to create join URL via MiroTalk API, falling back to manual generation",
            reason: inspect(reason)
          )

          # Fallback to manual generation if API fails
          join_url =
            JoinUrlBuilder.create_secure_direct_join_url(
              config,
              room_name,
              participant_name,
              role,
              meeting_time
            )

          {:ok, join_url}
      end
    else
      {:error, :invalid_parameters}
    end
  end

  @spec create_join_url(String.t(), term(), term()) ::
          {:error, :missing_room_id | :missing_participant_name}
  def create_join_url("", _participant_name, _participant_email), do: {:error, :missing_room_id}

  @spec create_join_url(term(), String.t(), term()) ::
          {:error, :missing_room_id | :missing_participant_name}
  def create_join_url(_room_id, "", _participant_email), do: {:error, :missing_participant_name}

  defdelegate create_join_url_via_api(config, room_id, participant_name, participant_email, role),
    to: JoinUrlBuilder

  defdelegate create_join_url_legacy(config, room_id, participant_name, participant_email),
    to: JoinUrlBuilder

  defdelegate create_direct_join_url(config, room_id, participant_name),
    to: JoinUrlBuilder

  defdelegate create_secure_direct_join_url(
                config,
                room_id,
                participant_name,
                role,
                meeting_time
              ),
              to: JoinUrlBuilder

  defdelegate generate_secure_token(config, room_id, user_name, role, meeting_time),
    to: JoinUrlBuilder

  defdelegate sanitize_input(text), to: JoinUrlBuilder

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def extract_room_id(meeting_url) when is_binary(meeting_url) and meeting_url != "" do
    # MiroTalk API returns the full meeting URL, but the 'room' parameter
    # and JWT payload expect only the room name (the last part of the URL).
    case URI.parse(meeting_url) do
      %URI{path: path} when is_binary(path) and path != "" ->
        path
        |> String.split("/")
        |> Enum.reject(&(&1 == ""))
        |> List.last()

      _other ->
        meeting_url
    end
  end

  def extract_room_id(_url), do: nil

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def valid_meeting_url?(meeting_url) do
    case URI.parse(meeting_url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _other ->
        false
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def handle_meeting_event(_event, _room_data, _additional_data) do
    :ok
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def generate_meeting_metadata(room_data) do
    %{
      provider: "mirotalk",
      meeting_id: room_data.room_id,
      join_url: room_data.meeting_url
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def build_config(integration, decrypted, _opts) do
    %{api_key: decrypted.api_key, base_url: integration.base_url}
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def credential_spec do
    %{
      required: [:base_url],
      credential_pairs: [{:api_key, :api_key_encrypted}],
      url_fields: [:base_url]
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def url_patterns, do: ["mirotalk", "talk."]
end
