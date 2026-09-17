defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client do
  @moduledoc """
  HTTP client for the Nextcloud Talk conversation API (OCS, API v4).

  Transport only: it builds the request, signs in with the login name and app
  password over HTTP Basic, and classifies the response. What a refusal means
  for a booking or an integration is decided by
  `Tymeslot.Integrations.Video.Providers.NextcloudTalkProvider`.

  Every request carries `OCS-APIRequest: true`, without which Nextcloud's CSRF
  check refuses it, and asks for JSON. Every request goes through the SSRF
  guard, which also refuses to follow redirects, so a redirect is reported
  rather than followed.

  Never probe a conversation with GET: Nextcloud counts a GET for an unknown
  token as a brute-force attempt against the calling address, whereas a DELETE
  for one is not.
  """

  alias Req.Response
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Video.Providers.SsrfOptions

  @capabilities_path "/ocs/v2.php/cloud/capabilities"
  @room_path "/ocs/v2.php/apps/spreed/api/v4/room"

  @receive_timeout_ms 15_000

  @type credentials :: %{
          required(:base_url) => String.t(),
          required(:client_id) => String.t(),
          required(:client_secret) => String.t(),
          optional(atom()) => term()
        }

  @typedoc """
  Why a request failed.

    * `:unauthorized`: Nextcloud refused the login name or app password (401)
    * `:not_found`: no such endpoint or conversation (404)
    * `{:redirected, location}`: the server answered with a redirect, never followed
    * `{:rejected, status, error}`: a 400 or 403, with the OCS `error` key when the body has one
    * `{:http_error, status}`: any other status outside 2xx
    * `:invalid_response`: a 2xx whose body is not the OCS JSON envelope
    * an exception: the request never completed (transport failure, SSRF refusal)
  """
  @type error ::
          :unauthorized
          | :not_found
          | {:redirected, String.t() | nil}
          | {:rejected, 400 | 403, String.t() | nil}
          | {:http_error, pos_integer()}
          | :invalid_response
          | Exception.t()

  @doc "Reads the server's capabilities as the signed-in user."
  @spec capabilities(credentials()) :: {:ok, term()} | {:error, error()}
  def capabilities(credentials), do: request(:get, credentials, @capabilities_path, nil)

  @doc "Creates a conversation and returns its OCS `data`, which carries the `token`."
  @spec create_room(credentials(), map()) :: {:ok, term()} | {:error, error()}
  def create_room(credentials, params), do: request(:post, credentials, @room_path, params)

  @doc "Sets a conversation's lobby state and the time the lobby lifts itself."
  @spec set_lobby(credentials(), String.t(), map()) :: {:ok, term()} | {:error, error()}
  def set_lobby(credentials, token, params),
    do: request(:put, credentials, room_path(token) <> "/webinar/lobby", params)

  @doc "Renames a conversation."
  @spec rename_room(credentials(), String.t(), String.t()) :: {:ok, term()} | {:error, error()}
  def rename_room(credentials, token, name),
    do: request(:put, credentials, room_path(token), %{"roomName" => name})

  @doc "Deletes a conversation."
  @spec delete_room(credentials(), String.t()) :: {:ok, term()} | {:error, error()}
  def delete_room(credentials, token), do: request(:delete, credentials, room_path(token), nil)

  defp room_path(token), do: @room_path <> "/" <> URI.encode_www_form(token)

  defp request(method, credentials, path, params) do
    url = String.trim_trailing(credentials.base_url, "/") <> path
    options = [receive_timeout: @receive_timeout_ms] ++ SsrfOptions.request_options()

    response =
      Config.http_client_module().request(
        method,
        url,
        encode(params),
        headers(credentials, params),
        options
      )

    classify(response)
  end

  defp encode(nil), do: ""
  defp encode(params), do: Jason.encode!(params)

  defp headers(credentials, params) do
    basic = Base.encode64(credentials.client_id <> ":" <> credentials.client_secret)

    [
      {"Authorization", "Basic " <> basic},
      {"OCS-APIRequest", "true"},
      {"Accept", "application/json"}
    ] ++ content_type(params)
  end

  defp content_type(nil), do: []
  defp content_type(_params), do: [{"Content-Type", "application/json"}]

  defp classify({:ok, %Response{status: status, body: body}}) when status in 200..299,
    do: ocs_data(body)

  defp classify({:ok, %Response{status: 401}}), do: {:error, :unauthorized}
  defp classify({:ok, %Response{status: 404}}), do: {:error, :not_found}

  defp classify({:ok, %Response{status: status} = response}) when status in 300..399 do
    {:error, {:redirected, response |> Response.get_header("location") |> List.first()}}
  end

  defp classify({:ok, %Response{status: status, body: body}}) when status in [400, 403],
    do: {:error, {:rejected, status, ocs_error(body)}}

  defp classify({:ok, %Response{status: status}}), do: {:error, {:http_error, status}}

  # Passed through untouched, so the circuit breaker recognises a transport
  # failure for what it is.
  defp classify({:error, reason}), do: {:error, reason}

  defp ocs_data(body) do
    case decode(body) do
      {:ok, %{"ocs" => %{"data" => data}}} -> {:ok, data}
      _other -> {:error, :invalid_response}
    end
  end

  defp ocs_error(body) do
    case decode(body) do
      {:ok, %{"ocs" => %{"data" => %{"error" => error}}}} when is_binary(error) -> error
      _other -> nil
    end
  end

  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_body), do: {:error, :not_a_binary}
end
