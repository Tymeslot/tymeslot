defmodule Tymeslot.Telegram.BotSetup do
  @moduledoc """
  Registers the Telegram bot webhook on startup (shared bot mode only).
  Idempotent — safe to call on every restart. Retries with exponential
  backoff if the Telegram API is temporarily unavailable during deployment.
  """

  require Logger

  alias Tymeslot.Telegram.API

  @max_retries 4
  @initial_delay_ms 2_000

  # Overridable so the retry ladder can be exercised without the suite paying
  # its real cost: at the production base delay, exhausting the retries sleeps
  # for 30 seconds.
  defp initial_delay_ms do
    Application.get_env(:tymeslot, :telegram_webhook_retry_delay_ms, @initial_delay_ms)
  end

  @spec register_webhook() :: :ok | {:error, term()}
  def register_webhook do
    do_register(0)
  end

  defp do_register(attempt) do
    bot_token = Application.get_env(:tymeslot, :telegram_bot_token)
    webhook_secret = Application.get_env(:tymeslot, :telegram_webhook_secret)

    cond do
      is_nil(bot_token) ->
        Logger.error(
          "Telegram bot webhook registration skipped — TELEGRAM_BOT_TOKEN not configured"
        )

        {:error, :missing_config}

      is_nil(webhook_secret) ->
        Logger.error(
          "Telegram bot webhook registration skipped — TELEGRAM_WEBHOOK_SECRET not configured"
        )

        {:error, :missing_config}

      true ->
        do_register_with_config(bot_token, webhook_secret, attempt)
    end
  end

  defp do_register_with_config(bot_token, webhook_secret, attempt) do
    endpoint_config = Application.get_env(:tymeslot, TymeslotWeb.Endpoint)
    host = System.get_env("PHX_HOST") || get_in(endpoint_config, [:url, :host])
    scheme = System.get_env("PHX_SCHEME") || get_in(endpoint_config, [:url, :scheme]) || "https"
    webhook_url = "#{scheme}://#{host}/api/telegram/webhook"

    case API.set_webhook(bot_token, webhook_url, webhook_secret) do
      {:ok, status, _body} when status >= 200 and status < 300 ->
        Logger.info("Telegram bot webhook registered successfully",
          webhook_url: webhook_url
        )

        :ok

      {:ok, status, response_body} ->
        Logger.error("Failed to register Telegram bot webhook",
          status: status,
          response: truncate(response_body, 2000),
          attempt: attempt + 1
        )

        retry_or_fail({:error, {:http_error, status}}, attempt, webhook_url)

      {:error, reason} ->
        Logger.error("Failed to register Telegram bot webhook",
          reason: reason,
          attempt: attempt + 1
        )

        retry_or_fail({:error, reason}, attempt, webhook_url)
    end
  end

  defp retry_or_fail(error, attempt, webhook_url) do
    if attempt < @max_retries do
      delay_ms = min(initial_delay_ms() * round(:math.pow(2, attempt)), 30_000)

      Logger.info("Retrying Telegram webhook registration",
        delay_ms: delay_ms,
        next_attempt: attempt + 2,
        max_attempts: @max_retries + 1,
        webhook_url: webhook_url
      )

      Process.sleep(delay_ms)
      do_register(attempt + 1)
    else
      Logger.error("Telegram webhook registration failed after all retries — webhook not active",
        attempts: @max_retries + 1
      )

      error
    end
  end

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max do
      String.slice(text, 0, max)
    else
      text
    end
  end

  defp truncate(other, _max), do: other
end
