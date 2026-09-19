defmodule Tymeslot.Integrations.Video.Providers.NextcloudTalk.Client do
  @moduledoc """
  Thin HTTP client for the parts of the Nextcloud OCS and Talk (spreed) APIs
  the Nextcloud Talk video provider uses.

  Every request authenticates with the account's username and app password
  (HTTP Basic) and sends the `OCS-APIRequest` header, without which Nextcloud
  refuses OCS calls made outside a browser session. Responses are decoded from
  the OCS envelope (`%{"ocs" => %{"meta" => _, "data" => _}}`) and only `data`
  is handed back.

  Failures are normalised into the shapes the rest of the video stack already
  understands, so neither the circuit breaker nor the room worker needs to know
  this provider exists:

    * `{:unauthorized, message}` - the server rejected the credentials (401)
    * `:rate_limited` - the server throttled the request (429), which is also
      how Nextcloud's brute-force protection answers
    * `{:http_error, status}` - a 5xx, i.e. the server is unwell
    * `{:http_error, status, body}` - any other unexpected status
    * `:not_found` - only from `get_room/2`, where a missing room is an answer
    * `:invalid_response` - a 2xx whose body is not the OCS JSON we expect
    * transport exceptions and `%SsrfBlockedError{}` are passed through untouched

  All requests go through the SSRF guard, scoped to the video opt-out
  (`ALLOW_PRIVATE_IPS_FOR_VIDEO`), exactly like the self-hosted MiroTalk
  provider.
  """

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Infrastructure.Logging.Redactor
  alias Tymeslot.Security.SsrfGuard

  @talk_api "/ocs/v2.php/apps/spreed/api/v4"
  @timeout 15_000

  @type config :: %{
          required(:base_url) => String.t(),
          required(:username) => String.t(),
          required(:app_password) => String.t(),
          optional(atom()) => term()
        }

  @type error ::
          {:unauthorized, String.t()}
          | :rate_limited
          | :invalid_response
          | {:http_error, pos_integer()}
          | {:http_error, pos_integer(), term()}
          | Exception.t()

  @doc """
  Fetches the authenticated account. Used to prove the credentials work: the
  capabilities endpoint answers anonymous requests too, so it cannot tell a
  wrong app password apart from a right one.
  """
  @spec get_current_user(config()) :: {:ok, map()} | {:error, error()}
  def get_current_user(config) do
    request(config, :get, "/ocs/v2.php/cloud/user")
  end

  @doc "Fetches the server capabilities as seen by the authenticated account."
  @spec get_capabilities(config()) :: {:ok, map()} | {:error, error()}
  def get_capabilities(config) do
    request(config, :get, "/ocs/v2.php/cloud/capabilities")
  end

  @doc """
  Creates a conversation. `params` is sent as the JSON body, e.g.
  `%{roomType: 3, roomName: "..."}`.
  """
  @spec create_room(config(), map()) :: {:ok, map()} | {:error, error()}
  def create_room(config, params) when is_map(params) do
    request(config, :post, "#{@talk_api}/room", params)
  end

  @doc "Fetches a conversation by token. A missing room is `{:error, :not_found}`."
  @spec get_room(config(), String.t()) :: {:ok, map()} | {:error, :not_found | error()}
  def get_room(config, token) do
    request(config, :get, "#{@talk_api}/room/#{encode_token(token)}", nil, not_found: true)
  end

  @doc "Sets the default permissions every non-moderator attendee receives."
  @spec set_default_permissions(config(), String.t(), non_neg_integer()) ::
          :ok | {:error, error()}
  def set_default_permissions(config, token, permissions) when is_integer(permissions) do
    config
    |> request(:put, "#{@talk_api}/room/#{encode_token(token)}/permissions/default", %{
      permissions: permissions
    })
    |> to_ok()
  end

  @doc """
  Detaches a conversation from the object it was created for (for an event
  conversation: its start and end time), so Talk's retention job no longer
  expires it. Requires the `unbind-conversation` capability.
  """
  @spec unbind_room_from_object(config(), String.t()) :: :ok | {:error, error()}
  def unbind_room_from_object(config, token) do
    config
    |> request(:delete, "#{@talk_api}/room/#{encode_token(token)}/object")
    |> to_ok()
  end

  @doc """
  Deletes a conversation. A room that no longer exists counts as deleted, so a
  retried cancellation stays idempotent.
  """
  @spec delete_room(config(), String.t()) :: :ok | {:error, error()}
  def delete_room(config, token) do
    case request(config, :delete, "#{@talk_api}/room/#{encode_token(token)}", nil,
           not_found: true
         ) do
      {:ok, _data} -> :ok
      {:error, :not_found} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The server's base URL without a trailing slash, the form every path above is
  appended to.
  """
  @spec normalize_base_url(String.t()) :: String.t()
  def normalize_base_url(base_url) when is_binary(base_url) do
    base_url |> String.trim() |> String.trim_trailing("/")
  end

  # ----- Private -----

  defp request(config, method, path, body \\ nil, opts \\ []) do
    url = normalize_base_url(config.base_url) <> path
    headers = headers(config, body)
    options = [timeout: @timeout] ++ ssrf_options()

    result =
      case method do
        :get -> Config.http_client_module().get(url, headers, options)
        :post -> Config.http_client_module().post(url, encode_body(body), headers, options)
        :put -> Config.http_client_module().put(url, encode_body(body), headers, options)
        :delete -> Config.http_client_module().delete(url, headers, options)
      end

    handle_response(result, method, path, opts)
  end

  defp headers(config, body) do
    base = [
      {"authorization", "Basic " <> Base.encode64("#{config.username}:#{config.app_password}")},
      {"ocs-apirequest", "true"},
      {"accept", "application/json"}
    ]

    if is_nil(body), do: base, else: [{"content-type", "application/json"} | base]
  end

  defp encode_body(nil), do: ""
  defp encode_body(body), do: Jason.encode!(body)

  # The same switch MiroTalk reads: a self-hosted Nextcloud on an internal
  # network is exactly the case `ALLOW_PRIVATE_IPS_FOR_VIDEO` exists for.
  defp ssrf_options do
    [ssrf_protect: true, ssrf_allow_private: SsrfGuard.allow_private_for_video?()]
  end

  # Room tokens are short alphanumeric strings; encoding keeps a malformed
  # stored value from rewriting the request path.
  defp encode_token(token), do: URI.encode(token, &URI.char_unreserved?/1)

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _method, _path, _opts)
       when status in 200..299 do
    decode_data(body)
  end

  defp handle_response({:ok, %Req.Response{status: 401}}, _method, _path, _opts) do
    {:error, {:unauthorized, "Nextcloud rejected the username or app password"}}
  end

  defp handle_response({:ok, %Req.Response{status: 404}}, _method, _path, opts) do
    if Keyword.get(opts, :not_found, false) do
      {:error, :not_found}
    else
      {:error, {:http_error, 404, nil}}
    end
  end

  defp handle_response({:ok, %Req.Response{status: 429}}, _method, _path, _opts) do
    {:error, :rate_limited}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, method, path, _opts)
       when status >= 500 do
    Logger.error("Nextcloud Talk server error",
      method: method,
      path: path,
      status: status,
      body: Redactor.redact_and_truncate(body)
    )

    {:error, {:http_error, status}}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, method, path, _opts) do
    Logger.warning("Unexpected Nextcloud Talk response",
      method: method,
      path: path,
      status: status,
      body: Redactor.redact_and_truncate(body)
    )

    {:error, {:http_error, status, error_data(body)}}
  end

  defp handle_response({:error, reason}, method, path, _opts) do
    Logger.warning("Nextcloud Talk request failed",
      method: method,
      path: path,
      error: Redactor.redact(reason)
    )

    {:error, reason}
  end

  defp decode_data(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"ocs" => %{"data" => data}}} -> {:ok, data}
      _other -> {:error, :invalid_response}
    end
  end

  defp decode_data(%{"ocs" => %{"data" => data}}), do: {:ok, data}
  defp decode_data(_body), do: {:error, :invalid_response}

  # Talk explains most 400s in `data.error` (e.g. "object-type"); keep just
  # that so the reason stays small and free of anything the server echoed back.
  defp error_data(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"ocs" => %{"data" => %{"error" => error}}}} when is_binary(error) -> error
      _other -> nil
    end
  end

  defp error_data(_body), do: nil

  defp to_ok({:ok, _data}), do: :ok
  defp to_ok({:error, _reason} = error), do: error
end
