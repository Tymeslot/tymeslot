defmodule Tymeslot.Telegram.BotSetup do
  @moduledoc """
  Registers the Telegram bot webhook on startup (shared bot mode only).
  Idempotent — safe to call on every restart.
  """

  require Logger

  @spec register_webhook() :: :ok | {:error, term()}
  def register_webhook do
    bot_token = Application.get_env(:tymeslot, :telegram_bot_token)
    webhook_secret = Application.get_env(:tymeslot, :telegram_webhook_secret)

    endpoint_config = Application.get_env(:tymeslot, TymeslotWeb.Endpoint)
    host = get_in(endpoint_config, [:url, :host])
    scheme = get_in(endpoint_config, [:url, :scheme]) || "https"
    webhook_url = "#{scheme}://#{host}/api/telegram/webhook"

    url = "https://api.telegram.org/bot#{bot_token}/setWebhook"

    body =
      Jason.encode!(%{
        url: webhook_url,
        secret_token: webhook_secret,
        allowed_updates: ["message"]
      })

    headers = [{"content-type", "application/json"}]

    case http_client().post(url, body, headers, receive_timeout: 10_000) do
      {:ok, %{status: status}} when status >= 200 and status < 300 ->
        Logger.info("Telegram bot webhook registered successfully",
          webhook_url: webhook_url
        )

        :ok

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Failed to register Telegram bot webhook",
          status: status,
          response: response_body
        )

        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.error("Failed to register Telegram bot webhook",
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp http_client do
    Application.get_env(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
  end
end
