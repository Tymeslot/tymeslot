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
  for one is not. Listing the signed-in user's conversations carries no such
  protection, so a conversation is looked for there instead.

  A conversation token is checked against Talk's own route constraint (4 to 30
  lowercase letters and digits) before any request is built, so a malformed
  token can never reshape the request path.
  """

  alias Req.Response
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.HTTPClient
  alias Tymeslot.Integrations.Video.Providers.SsrfOptions

  @capabilities_path "/ocs/v2.php/cloud/capabilities"
  @room_path "/ocs/v2.php/apps/spreed/api/v4/room"

  # Only what a lookup reads: no last message, and the user's online status
  # left alone, which a listing would otherwise refresh.
  @list_rooms_query "?noStatusUpdate=1&includeLastMessage=0"

  # `request_timeout` caps each whole response, so `request_budget_ms/1` is a
  # real bound: without it the receive timeout would apply per chunk.
  @timeouts [receive_timeout: 15_000, request_timeout: 15_000, connect_options: [timeout: 5_000]]

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
    * `:rate_limited`: Nextcloud's rate limit or brute-force protection refused the calling address (429)
    * `{:http_error, status}`: any other status outside 2xx
    * `:invalid_response`: a 2xx whose body is not the OCS JSON envelope
    * `:invalid_token`: the conversation token does not match Talk's token format; no request was sent
    * an exception: the request never completed (transport failure, SSRF refusal)
  """
  @type error ::
          :unauthorized
          | :not_found
          | {:redirected, String.t() | nil}
          | {:rejected, 400 | 403, String.t() | nil}
          | :rate_limited
          | {:http_error, pos_integer()}
          | :invalid_response
          | :invalid_token
          | Exception.t()

  @doc "Reads the server's capabilities as the signed-in user."
  @spec capabilities(credentials()) :: {:ok, term()} | {:error, error()}
  def capabilities(credentials), do: request(:get, credentials, @capabilities_path, nil)

  @doc """
  Lists the conversations the signed-in user takes part in, each as its OCS
  room map, which carries the `token` and the `description`.
  """
  @spec list_rooms(credentials()) :: {:ok, term()} | {:error, error()}
  def list_rooms(credentials),
    do: request(:get, credentials, @room_path <> @list_rooms_query, nil)

  @doc "Creates a conversation and returns its OCS `data`, which carries the `token`."
  @spec create_room(credentials(), map()) :: {:ok, term()} | {:error, error()}
  def create_room(credentials, params), do: request(:post, credentials, @room_path, params)

  @doc """
  Sets a conversation's lobby state and the time the lobby lifts itself.

  `params` carries `"state"` (0 for no lobby, 1 for a lobby for everyone but
  moderators) and an optional `"timer"`: the moment the lobby lifts, as a Unix
  timestamp in seconds.
  """
  @spec set_lobby(credentials(), String.t(), map()) :: {:ok, term()} | {:error, error()}
  def set_lobby(credentials, token, params) do
    with {:ok, path} <- room_path(token),
         do: request(:put, credentials, path <> "/webinar/lobby", params)
  end

  @doc "Renames a conversation."
  @spec rename_room(credentials(), String.t(), String.t()) :: {:ok, term()} | {:error, error()}
  def rename_room(credentials, token, name) do
    with {:ok, path} <- room_path(token),
         do: request(:put, credentials, path, %{"roomName" => name})
  end

  @doc "Deletes a conversation."
  @spec delete_room(credentials(), String.t()) :: {:ok, term()} | {:error, error()}
  def delete_room(credentials, token) do
    with {:ok, path} <- room_path(token), do: request(:delete, credentials, path, nil)
  end

  @doc """
  The longest one request to Nextcloud can wait on the network, in
  milliseconds, derived from the timeouts every request is sent with.
  """
  @spec request_budget_ms(atom()) :: pos_integer()
  def request_budget_ms(method), do: HTTPClient.request_budget_ms(method, @timeouts)

  @doc """
  Whether `token` matches Talk's route requirement for a conversation token:
  4 to 30 lowercase letters and digits. Talk routes nothing else, so a token
  that fails this addresses no conversation.
  """
  @spec valid_token?(term()) :: boolean()
  def valid_token?(token) when is_binary(token), do: token =~ ~r/\A[a-z0-9]{4,30}\z/
  def valid_token?(_token), do: false

  # Anything Talk would not route is refused here rather than sent.
  defp room_path(token) do
    if valid_token?(token),
      do: {:ok, @room_path <> "/" <> token},
      else: {:error, :invalid_token}
  end

  defp request(method, credentials, path, params) do
    url = String.trim_trailing(credentials.base_url, "/") <> path

    options = @timeouts ++ SsrfOptions.request_options()

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
  defp classify({:ok, %Response{status: 429}}), do: {:error, :rate_limited}

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
