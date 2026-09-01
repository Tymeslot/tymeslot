defmodule Tymeslot.Telegram.API do
  @moduledoc """
  Low-level HTTP client for the Telegram Bot API.
  All outbound requests to api.telegram.org go through this module.
  """

  alias Tymeslot.Infrastructure.Config

  @base_url "https://api.telegram.org/bot"
  @timeout_ms 10_000

  @spec send_message(String.t(), String.t() | integer(), String.t()) ::
          {:ok, non_neg_integer(), String.t()} | {:error, String.t()}
  def send_message(bot_token, chat_id, text) do
    post("#{bot_token}/sendMessage", %{
      chat_id: chat_id,
      text: text,
      parse_mode: "HTML",
      disable_web_page_preview: true
    })
  end

  # The body is `Req.Response.body`. `Tymeslot.Infrastructure.HTTPClient` sets
  # `decode_body: false`, so this is always the raw binary Telegram sent, not
  # a decoded map — callers that need the parsed JSON call `Jason.decode/1`
  # themselves.
  @spec set_webhook(String.t(), String.t(), String.t()) ::
          {:ok, non_neg_integer(), String.t()} | {:error, String.t()}
  def set_webhook(bot_token, webhook_url, secret_token) do
    post("#{bot_token}/setWebhook", %{
      url: webhook_url,
      secret_token: secret_token,
      allowed_updates: ["message"]
    })
  end

  defp post(path, params) do
    url = @base_url <> path
    body = Jason.encode!(params)
    headers = [{"content-type", "application/json"}]

    case Config.http_client_module().post(url, body, headers, receive_timeout: @timeout_ms) do
      {:ok, %{status: status, body: response_body}} ->
        {:ok, status, response_body}

      {:error, %{reason: reason}} ->
        {:error, inspect(reason)}

      {:error, reason} ->
        {:error, redact_error(reason)}
    end
  end

  # `reason` here is whatever the configured HTTP client module returns
  # outside the `%{reason: ...}` shape above — notably
  # `Tymeslot.Infrastructure.ResponseTooLargeError`, whose struct carries the
  # full request URL, and the bot token lives in that URL's path. Exceptions
  # already define a redacted `message/1` (`ResponseTooLargeError.message/1`
  # prints scheme and host only); anything else falls back to `inspect/1`,
  # which is safe only because no other shape reaching this branch carries a
  # URL today.
  defp redact_error(reason) when is_exception(reason), do: Exception.message(reason)
  defp redact_error(reason), do: inspect(reason)
end
