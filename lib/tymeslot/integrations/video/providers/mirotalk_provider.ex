defmodule Tymeslot.Integrations.Video.Providers.MiroTalkProvider do
  @moduledoc """
  MiroTalk P2P video conferencing provider implementation.

  Provides functions to create meeting rooms, generate join URLs, and manage
  video conferencing sessions for scheduled appointments.
  """

  @behaviour Tymeslot.Integrations.Video.Providers.ProviderBehaviour

  require Logger
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Security.{RateLimiter, UrlValidation}

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def provider_type, do: :mirotalk

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def display_name, do: "MiroTalk P2P"

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def config_schema do
    %{
      api_key: %{type: :string, required: true, description: "API key for MiroTalk server"},
      base_url: %{type: :string, required: true, description: "Base URL of MiroTalk server"}
    }
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def validate_config(config) do
    required_fields = [:api_key, :base_url]
    missing_fields = required_fields -- Map.keys(config)

    if Enum.empty?(missing_fields) do
      # All required fields present, now test the actual connection
      case test_connection(config) do
        {:ok, _message} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def capabilities do
    %{
      recording: false,
      screen_sharing: true,
      waiting_room: false,
      max_participants: 100,
      requires_download: false,
      supports_phone_dial_in: false,
      supports_chat: true,
      supports_breakout_rooms: false,
      end_to_end_encryption: true
    }
  end

  @doc """
  Tests the connection to the MiroTalk API.
  """
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def test_connection(config, opts \\ []) do
    # Extract IP address for rate limiting
    ip_address = get_in(opts, [:metadata, :ip]) || "127.0.0.1"

    # For MiroTalk, we can test by checking if the API endpoint is reachable
    base_url = Map.get(config, :base_url)
    api_key = Map.get(config, :api_key)

    with :ok <- check_rate_limit(ip_address),
         :ok <- validate_base_url(base_url) do
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
    options = [timeout: 5_000]

    # Always try HTTPS first; if it fails due to network/connection, fall back to HTTP
    handle_api_response(
      try_https_then_http(base_url, "/api/v1/meeting", fn url ->
        http_client().post(url, "", headers, options)
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
  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_meeting_room(config) do
    base_url = Map.get(config, :base_url)

    headers = [
      {"authorization", Map.get(config, :api_key)},
      {"Content-Type", "application/json"}
    ]

    # Try HTTPS first, then HTTP
    case try_https_then_http(base_url, "/api/v1/meeting", fn url ->
           http_client().post(url, "", headers, [])
         end) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        case Jason.decode(body) do
          {:ok, response} ->
            {:ok,
             %{
               room_id: response["room_id"] || response["meeting"],
               meeting_url: response["meeting_url"] || response["meeting"],
               provider_data: response,
               provider_config: config
             }}

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

  @impl Tymeslot.Integrations.Video.Providers.ProviderBehaviour
  def create_join_url(room_data, participant_name, participant_email, role, meeting_time) do
    room_id = room_data[:room_id] || room_data["room_id"]
    config = room_data[:provider_config] || room_data["provider_config"]

    if room_id != "" and participant_name != "" and config do
      # MiroTalk API returns the full meeting URL, but the 'room' parameter
      # for the join API expects only the room name (UUID).
      room_name = extract_room_id(room_id)

      # We prefer using the MiroTalk API to generate the join URL.
      # This ensures the token is generated by the server itself and is guaranteed to be valid.
      case create_join_url_via_api(config, room_name, participant_name, participant_email, role) do
        {:ok, join_url} ->
          {:ok, join_url}

        {:error, reason} ->
          Logger.warning(
            "Failed to create join URL via MiroTalk API, falling back to manual generation",
            reason: inspect(reason)
          )

          # Fallback to manual generation if API fails
          join_url =
            create_secure_direct_join_url(config, room_name, participant_name, role, meeting_time)

          {:ok, join_url}
      end
    else
      {:error, :invalid_parameters}
    end
  end

  @doc """
  Creates a join URL by calling the MiroTalk /api/v1/join endpoint.
  """
  @spec create_join_url_via_api(
          map(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, String.t()} | {:error, String.t()}
  def create_join_url_via_api(config, room_id, participant_name, _participant_email, role) do
    base_url = Map.get(config, :base_url)

    headers = [
      {"authorization", Map.get(config, :api_key)},
      {"Content-Type", "application/json"}
    ]

    # Map role to Mirotalk standard roles
    mirotalk_role =
      case role do
        "organizer" -> "admin"
        _other -> "guest"
      end

    body =
      Jason.encode!(%{
        room: room_id,
        name: sanitize_input(participant_name),
        role: mirotalk_role,
        avatar: false,
        audio: true,
        video: true,
        screen: if(mirotalk_role == "admin", do: true, else: false),
        hide: false,
        notify: true
      })

    handle_join_api_response(
      try_https_then_http(base_url, "/api/v1/join", fn url ->
        http_client().post(url, body, headers, [])
      end),
      :with_validation
    )
  end

  # Keep the old function for backward compatibility
  @spec create_join_url_legacy(map(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_join_url_legacy(config, room_id, participant_name, _participant_email)
      when room_id != "" and participant_name != "" do
    base_url = Map.get(config, :base_url)

    headers = [
      {"authorization", Map.get(config, :api_key)},
      {"Content-Type", "application/json"}
    ]

    # Sanitize participant name to prevent XSS
    sanitized_name = sanitize_input(participant_name)

    body =
      Jason.encode!(%{
        room: room_id,
        name: sanitized_name,
        avatar: false,
        audio: true,
        video: true,
        screen: false,
        hide: false,
        notify: true
      })

    handle_join_api_response(
      try_https_then_http(base_url, "/api/v1/join", fn url ->
        http_client().post(url, body, headers, [])
      end),
      :legacy
    )
  end

  @spec create_join_url(String.t(), term(), term()) ::
          {:error, :missing_room_id | :missing_participant_name}
  def create_join_url("", _participant_name, _participant_email), do: {:error, :missing_room_id}

  @spec create_join_url(term(), String.t(), term()) ::
          {:error, :missing_room_id | :missing_participant_name}
  def create_join_url(_room_id, "", _participant_email), do: {:error, :missing_participant_name}

  @spec create_direct_join_url(map(), String.t(), String.t()) :: String.t()
  def create_direct_join_url(config, room_id, participant_name) do
    base_url = "#{Map.get(config, :base_url)}/join"

    # Sanitize participant name
    sanitized_name = sanitize_input(participant_name)

    params = %{
      room: room_id,
      name: sanitized_name,
      audio: 1,
      video: 1,
      screen: 0,
      hide: 0,
      notify: 1
    }

    query_string = URI.encode_query(params)
    "#{base_url}?#{query_string}"
  end

  @spec create_secure_direct_join_url(map(), String.t(), String.t(), String.t(), DateTime.t()) ::
          String.t()
  def create_secure_direct_join_url(config, room_id, participant_name, role, meeting_time) do
    base_url = "#{Map.get(config, :base_url)}/join"

    # Map role to Mirotalk standard roles (admin/guest)
    mirotalk_role =
      case role do
        "organizer" -> "admin"
        _other -> "guest"
      end

    # Generate secure token (Standard JWT)
    token = generate_secure_token(config, room_id, participant_name, mirotalk_role, meeting_time)

    # Sanitize participant name
    sanitized_name = sanitize_input(participant_name)

    params = %{
      room: room_id,
      name: sanitized_name,
      role: mirotalk_role,
      token: token,
      audio: 1,
      video: 1,
      screen: if(mirotalk_role == "admin", do: 1, else: 0),
      hide: 0,
      notify: 1,
      exp: DateTime.to_unix(meeting_time)
    }

    query_string = URI.encode_query(params)
    "#{base_url}?#{query_string}"
  end

  @spec generate_secure_token(map(), String.t(), String.t(), String.t(), DateTime.t()) ::
          String.t()
  def generate_secure_token(config, room_id, user_name, role, meeting_time) do
    secret = Map.get(config, :api_key)

    # JWT Header
    header = %{alg: "HS256", typ: "JWT"}

    # Create payload with room info, user info, role, and expiry.
    # Standard MiroTalk P2P expects 'room' and 'role' claims.
    payload = %{
      room: room_id,
      user: sanitize_input(user_name),
      role: role,
      exp: DateTime.to_unix(meeting_time),
      iat: DateTime.to_unix(DateTime.utc_now()),
      jti: UUID.uuid4()
    }

    # Standard JWT generation: header.payload.signature
    encoded_header = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    encoded_payload = payload |> Jason.encode!() |> Base.url_encode64(padding: false)

    signing_input = encoded_header <> "." <> encoded_payload

    signature =
      Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, signing_input), padding: false)

    encoded_header <> "." <> encoded_payload <> "." <> signature
  end

  @spec sanitize_input(String.t()) :: String.t()
  def sanitize_input(text) when is_binary(text) do
    text
    |> String.replace(~r/[^\p{L}\p{N} .\-_'@]/u, "")
    |> String.slice(0, 64)
  end

  @spec sanitize_input(term()) :: String.t()
  def sanitize_input(_non_string), do: ""

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
      meeting_id: room_data[:room_id] || room_data["room_id"],
      join_url: room_data[:meeting_url] || room_data["meeting_url"]
    }
  end

  # Rate limit helper
  defp check_rate_limit(ip) do
    case RateLimiter.check_mirotalk_connection_rate_limit(ip) do
      :ok -> :ok
      {:error, :rate_limited, message} -> {:error, message}
    end
  end

  # Handle MiroTalk join API response
  defp handle_join_api_response(http_result, mode) do
    case http_result do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, response} ->
            case mode do
              :with_validation ->
                if response["join"] do
                  {:ok, response["join"]}
                else
                  Logger.error("MiroTalk API response missing 'join' field",
                    response: inspect(response)
                  )

                  {:error, :missing_join_url}
                end

              :legacy ->
                {:ok, response["join"]}
            end

          {:error, _decode_error} ->
            error_msg =
              if mode == :with_validation,
                do: "Invalid JSON response from MiroTalk API join endpoint",
                else: "Invalid JSON response from MiroTalk API"

            Logger.error(error_msg)
            {:error, :invalid_json}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        error_msg =
          if mode == :with_validation,
            do: "MiroTalk join API error",
            else: "MiroTalk API error"

        redacted_body = Redactor.redact_and_truncate(body)

        Logger.error("MiroTalk API error",
          message: error_msg,
          status: status,
          body: redacted_body
        )

        {:error, {:http_error, status, "#{error_msg} (see logs for details)"}}

      {:error, reason} ->
        error_msg =
          if mode == :with_validation,
            do: "Failed to call MiroTalk join API: #{Redactor.redact(reason)}",
            else: "Failed to create join URL: #{Redactor.redact(reason)}"

        Logger.error(error_msg)
        {:error, reason}
    end
  end

  # Internal: attempt HTTPS first (by forcing https scheme), then fall back to the provided base_url
  defp try_https_then_http(base_url, path, fun) when is_binary(base_url) and is_binary(path) do
    https_url = force_https(base_url) <> path

    case fun.(https_url) do
      {:ok, %Req.Response{} = resp} ->
        {:ok, resp}

      {:error, exception} when is_exception(exception) ->
        # Fallback to original base_url on network/connection error
        fallback_url = base_url <> path

        case fun.(fallback_url) do
          {:ok, %Req.Response{} = resp2} -> {:ok, resp2}
          {:error, exception2} when is_exception(exception2) -> {:error, exception2}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp try_https_then_http(base_url, path, fun) do
    # If inputs are unexpected, just attempt with concatenation
    fun.(base_url <> path)
  end

  defp force_https(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.put(:scheme, "https")
    |> Map.put(:port, 443)
    |> URI.to_string()
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, HTTPClient)
  end
end
