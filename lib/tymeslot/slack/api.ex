defmodule Tymeslot.Slack.API do
  @moduledoc """
  Low-level HTTP wrapper for Slack APIs.

  Two delivery modes:
    * **OAuth** — `POST https://slack.com/api/chat.postMessage` with a bot token
    * **Webhook URL** — `POST` directly to the user-supplied `hooks.slack.com` URL

  All public functions return `{:ok, body}` for successful Slack responses or
  `{:error, reason}` for transport/HTTP/Slack errors. Slack's `"ok": false`
  bodies are translated into `{:error, {:slack_error, code, body}}` so callers
  do not have to inspect the body to detect failure.
  """

  @base_url "https://slack.com/api"
  @timeout_ms 10_000

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Posts a Block Kit message via the Web API using a bot token.

  Sets `unfurl_links: false` and `unfurl_media: false` to keep posted messages
  compact — otherwise Slack auto-expands the meeting URL.
  """
  @spec post_message_via_token(String.t(), String.t(), [map()]) ::
          {:ok, map()} | {:error, term()}
  def post_message_via_token(bot_token, channel_id, blocks) when is_list(blocks) do
    body = %{
      channel: channel_id,
      blocks: blocks,
      text: extract_fallback_text(blocks),
      unfurl_links: false,
      unfurl_media: false
    }

    headers = [
      {"authorization", "Bearer #{bot_token}"},
      {"content-type", "application/json; charset=utf-8"}
    ]

    "#{@base_url}/chat.postMessage"
    |> http_post(Jason.encode!(body), headers)
    |> parse_web_api_response()
  end

  @doc "Posts a Block Kit message via an Incoming Webhook URL."
  @spec post_message_via_webhook(String.t(), [map()]) :: {:ok, map()} | {:error, term()}
  def post_message_via_webhook(webhook_url, blocks) when is_list(blocks) do
    body = %{blocks: blocks, text: extract_fallback_text(blocks)}
    headers = [{"content-type", "application/json; charset=utf-8"}]

    webhook_url
    |> http_post(Jason.encode!(body), headers)
    |> parse_webhook_response()
  end

  @doc """
  Lists conversations (channels) the bot can post to.

  Pass `cursor:` to fetch the next page. The bot must have `channels:read`
  (and `groups:read` for private channels) scope.
  """
  @spec list_conversations(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_conversations(bot_token, opts \\ []) do
    types = Keyword.get(opts, :types, "public_channel,private_channel")
    limit = Keyword.get(opts, :limit, 200)
    cursor = Keyword.get(opts, :cursor)

    query =
      [{"types", types}, {"limit", to_string(limit)}, {"exclude_archived", "true"}]
      |> maybe_put_cursor(cursor)
      |> URI.encode_query()

    headers = [{"authorization", "Bearer #{bot_token}"}]

    "#{@base_url}/conversations.list?#{query}"
    |> http_get(headers)
    |> parse_web_api_response()
  end

  @doc "Exchanges an OAuth code for a bot token."
  @spec oauth_v2_access(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def oauth_v2_access(client_id, client_secret, code, redirect_uri) do
    body =
      URI.encode_query(%{
        client_id: client_id,
        client_secret: client_secret,
        code: code,
        redirect_uri: redirect_uri
      })

    headers = [{"content-type", "application/x-www-form-urlencoded"}]

    "#{@base_url}/oauth.v2.access"
    |> http_post(body, headers)
    |> parse_web_api_response()
  end

  @doc "Verifies a bot token is still valid."
  @spec auth_test(String.t()) :: {:ok, map()} | {:error, term()}
  def auth_test(bot_token) do
    headers = [{"authorization", "Bearer #{bot_token}"}]

    "#{@base_url}/auth.test"
    |> http_post("", headers)
    |> parse_web_api_response()
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp http_post(url, body, headers) do
    http_client().post(url, body, headers, receive_timeout: @timeout_ms)
  end

  defp http_get(url, headers) do
    http_client().get(url, headers, receive_timeout: @timeout_ms)
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end

  defp maybe_put_cursor(params, nil), do: params
  defp maybe_put_cursor(params, ""), do: params
  defp maybe_put_cursor(params, cursor), do: params ++ [{"cursor", cursor}]

  # Slack Web API: 200 with `{"ok": true, ...}` or `{"ok": false, "error": "..."}`.
  defp parse_web_api_response({:ok, %{status: 200, body: body}}) do
    case decode_body(body) do
      {:ok, %{"ok" => true} = decoded} -> {:ok, decoded}
      {:ok, %{"ok" => false, "error" => err} = decoded} -> {:error, {:slack_error, err, decoded}}
      {:ok, decoded} -> {:error, {:slack_error, "unknown", decoded}}
      {:error, _reason} -> {:error, {:http_error, 200, body}}
    end
  end

  defp parse_web_api_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp parse_web_api_response({:error, reason}), do: {:error, {:transport_error, reason}}

  # Webhook URL: 200 with body "ok" on success, 4xx with body like "no_text" / "invalid_payload"
  # on failure.
  defp parse_webhook_response({:ok, %{status: 200}}), do: {:ok, %{}}

  defp parse_webhook_response({:ok, %{status: status, body: body}}) when status in 400..499,
    do: {:error, {:webhook_error, status, to_string(body)}}

  defp parse_webhook_response({:ok, %{status: status, body: body}}),
    do: {:error, {:http_error, status, body}}

  defp parse_webhook_response({:error, reason}), do: {:error, {:transport_error, reason}}

  defp decode_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_body(body) when is_map(body), do: {:ok, body}
  defp decode_body(_other), do: {:error, :invalid_body}

  # Extract a fallback text string for accessibility / push notifications.
  defp extract_fallback_text(blocks) do
    Enum.find_value(blocks, "Tymeslot notification", fn
      %{"type" => "header", "text" => %{"text" => text}} -> text
      %{"type" => "section", "text" => %{"text" => text}} -> text
      _block -> nil
    end)
  end
end
