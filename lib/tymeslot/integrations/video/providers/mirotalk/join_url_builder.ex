defmodule Tymeslot.Integrations.Video.Providers.MiroTalk.JoinUrlBuilder do
  @moduledoc """
  Builds join URLs for MiroTalk P2P video conferencing sessions.

  Supports three strategies:
  - API-based generation via the MiroTalk `/api/v1/join` endpoint
  - Legacy API-based generation (backward-compatible variant)
  - Direct URL construction with optional HMAC-signed JWT tokens
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Integrations.Video.Providers.MiroTalk.HttpHelpers

  @type config :: %{required(:api_key) => String.t(), required(:base_url) => String.t()}

  # ---------------------------------------------------------------------------
  # API-based join URL generation
  # ---------------------------------------------------------------------------

  @doc """
  Creates a join URL by calling the MiroTalk `/api/v1/join` endpoint.
  """
  @spec create_join_url_via_api(config(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, String.t()}
  def create_join_url_via_api(config, room_id, participant_name, _participant_email, role) do
    base_url = Map.get(config, :base_url)

    headers = [
      {"authorization", Map.get(config, :api_key)},
      {"Content-Type", "application/json"}
    ]

    mirotalk_role = map_role(role)

    body =
      Jason.encode!(%{
        room: room_id,
        name: sanitize_input(participant_name),
        role: mirotalk_role,
        avatar: false,
        audio: true,
        video: true,
        screen: mirotalk_role == "admin",
        hide: false,
        notify: true
      })

    handle_join_api_response(
      HttpHelpers.try_https_then_http(base_url, "/api/v1/join", fn url ->
        Config.http_client_module().post(url, body, headers, HttpHelpers.ssrf_options())
      end),
      :with_validation
    )
  end

  @doc """
  Creates a join URL via the legacy MiroTalk API path (backward-compatible).
  """
  @spec create_join_url_legacy(config(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_join_url_legacy(config, room_id, participant_name, _participant_email)
      when room_id != "" and participant_name != "" do
    base_url = Map.get(config, :base_url)

    headers = [
      {"authorization", Map.get(config, :api_key)},
      {"Content-Type", "application/json"}
    ]

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
      HttpHelpers.try_https_then_http(base_url, "/api/v1/join", fn url ->
        Config.http_client_module().post(url, body, headers, HttpHelpers.ssrf_options())
      end),
      :legacy
    )
  end

  # ---------------------------------------------------------------------------
  # Direct URL construction
  # ---------------------------------------------------------------------------

  @doc """
  Builds a direct join URL with query parameters (no authentication token).
  """
  @spec create_direct_join_url(config(), String.t(), String.t()) :: String.t()
  def create_direct_join_url(config, room_id, participant_name) do
    base_url = "#{Map.get(config, :base_url)}/join"
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

  @doc """
  Builds a direct join URL with an HMAC-signed JWT token for secure access.
  """
  @spec create_secure_direct_join_url(config(), String.t(), String.t(), String.t(), DateTime.t()) ::
          String.t()
  def create_secure_direct_join_url(config, room_id, participant_name, role, meeting_time) do
    base_url = "#{Map.get(config, :base_url)}/join"
    mirotalk_role = map_role(role)
    token = generate_secure_token(config, room_id, participant_name, mirotalk_role, meeting_time)
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

  # ---------------------------------------------------------------------------
  # Token generation
  # ---------------------------------------------------------------------------

  @doc """
  Generates an HMAC-SHA256 signed JWT token for MiroTalk room access.
  """
  @spec generate_secure_token(config(), String.t(), String.t(), String.t(), DateTime.t()) ::
          String.t()
  def generate_secure_token(config, room_id, user_name, role, meeting_time) do
    secret = Map.get(config, :api_key)

    header = %{alg: "HS256", typ: "JWT"}

    payload = %{
      room: room_id,
      user: sanitize_input(user_name),
      role: role,
      exp: DateTime.to_unix(meeting_time),
      iat: DateTime.to_unix(DateTime.utc_now()),
      jti: UUID.uuid4()
    }

    encoded_header = header |> Jason.encode!() |> Base.url_encode64(padding: false)
    encoded_payload = payload |> Jason.encode!() |> Base.url_encode64(padding: false)

    signing_input = encoded_header <> "." <> encoded_payload

    signature =
      Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, signing_input), padding: false)

    encoded_header <> "." <> encoded_payload <> "." <> signature
  end

  # ---------------------------------------------------------------------------
  # Input sanitisation
  # ---------------------------------------------------------------------------

  @doc """
  Sanitises user input by stripping potentially dangerous characters.
  """
  @spec sanitize_input(String.t()) :: String.t()
  def sanitize_input(text) when is_binary(text) do
    text
    |> String.replace(~r/[^\p{L}\p{N} .\-_'@]/u, "")
    |> String.slice(0, 64)
  end

  @spec sanitize_input(term()) :: String.t()
  def sanitize_input(_non_string), do: ""

  # ---------------------------------------------------------------------------
  # API response handling
  # ---------------------------------------------------------------------------

  @doc false
  @spec handle_join_api_response(
          {:ok, Req.Response.t()} | {:error, term()},
          :with_validation | :legacy
        ) :: {:ok, String.t()} | {:error, term()}
  def handle_join_api_response(http_result, mode) do
    case http_result do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, response} ->
            extract_join_url(response, mode)

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp extract_join_url(response, :with_validation) do
    if response["join"] do
      {:ok, response["join"]}
    else
      Logger.error("MiroTalk API response missing 'join' field",
        response: inspect(response)
      )

      {:error, :missing_join_url}
    end
  end

  defp extract_join_url(response, :legacy) do
    {:ok, response["join"]}
  end

  defp map_role("organizer"), do: "admin"
  defp map_role(_other), do: "guest"
end
