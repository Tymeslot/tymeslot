defmodule TymeslotWeb.TelegramWebhookController do
  use TymeslotWeb, :controller

  require Logger

  alias Plug.Crypto
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Telegram
  alias TymeslotWeb.Helpers.ClientIP

  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, params) do
    if Telegram.telegram_enabled?() and Telegram.shared_bot_mode?() do
      client_ip = ClientIP.get(conn)

      case RateLimiter.check_webhook_rate_limit(client_ip) do
        :ok ->
          case verify_secret(conn) do
            :ok ->
              handle_update(conn, params)

            {:error, :invalid_secret} ->
              conn |> put_status(403) |> json(%{error: "forbidden"}) |> halt()
          end

        {:error, :rate_limited} ->
          conn |> put_status(429) |> json(%{error: "too many requests"}) |> halt()
      end
    else
      conn |> put_status(404) |> json(%{error: "not found"}) |> halt()
    end
  end

  defp verify_secret(conn) do
    expected = Application.get_env(:tymeslot, :telegram_webhook_secret)
    received = List.first(get_req_header(conn, "x-telegram-bot-api-secret-token"))

    if expected && received && Crypto.secure_compare(expected, received) do
      :ok
    else
      {:error, :invalid_secret}
    end
  end

  defp handle_update(conn, %{"message" => %{"text" => text, "chat" => %{"id" => chat_id}}}) do
    case parse_start_command(text) do
      {:ok, token} ->
        case Telegram.handle_start_payload(token, chat_id) do
          {:ok, integration} ->
            Logger.info("Telegram account linked via deep link",
              chat_id: chat_id,
              integration_id: integration.id,
              user_id: integration.user_id
            )

            json(conn, %{ok: true})

          {:error, reason} ->
            Logger.warning("Failed to link Telegram account",
              chat_id: chat_id,
              reason: inspect(reason)
            )

            json(conn, %{ok: true})
        end

      :ignore ->
        json(conn, %{ok: true})
    end
  end

  defp handle_update(conn, _params) do
    json(conn, %{ok: true})
  end

  defp parse_start_command("/start " <> token) when byte_size(token) > 0, do: {:ok, token}
  defp parse_start_command(_other), do: :ignore
end
