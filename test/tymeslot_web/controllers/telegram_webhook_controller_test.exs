defmodule TymeslotWeb.TelegramWebhookControllerTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :telegram
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Telegram

  @webhook_secret "test_webhook_secret_123"

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      telegram_notifications_allowed: true,
      telegram_shared_bot: true,
      telegram_webhook_secret: @webhook_secret,
      telegram_bot_token: "shared_token_123",
      telegram_bot_username: "test_bot"
    )

    :ok
  end

  describe "POST /api/telegram/webhook" do
    test "links account with valid start payload", %{conn: conn} do
      token = Telegram.generate_link_token()

      integration =
        insert(:telegram_integration, chat_id: nil, bot_mode: "shared", link_token: token)

      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post("/api/telegram/webhook", %{
          "message" => %{
            "text" => "/start #{token}",
            "chat" => %{"id" => 12_345}
          }
        })

      assert json_response(conn, 200)["ok"] == true

      assert {:ok, updated} = Telegram.get_integration(integration.id, integration.user_id)
      assert updated.chat_id == "12345"
    end

    test "returns 403 with invalid secret", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", "wrong_secret")
        |> post("/api/telegram/webhook", %{
          "message" => %{
            "text" => "/start test_token",
            "chat" => %{"id" => 12_345}
          }
        })

      assert json_response(conn, 403)["error"] == "forbidden"
    end

    test "returns 403 with missing secret", %{conn: conn} do
      conn =
        post(conn, "/api/telegram/webhook", %{
          "message" => %{
            "text" => "/start test_token",
            "chat" => %{"id" => 12_345}
          }
        })

      assert json_response(conn, 403)["error"] == "forbidden"
    end

    test "returns 404 when telegram is disabled", %{conn: conn} do
      with_config(:tymeslot, telegram_notifications_allowed: false)

      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post("/api/telegram/webhook", %{})

      assert json_response(conn, 404)["error"] == "not found"
    end

    test "returns 404 when shared bot mode is off", %{conn: conn} do
      with_config(:tymeslot, telegram_shared_bot: false)

      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post("/api/telegram/webhook", %{})

      assert json_response(conn, 404)["error"] == "not found"
    end

    test "handles expired token gracefully", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post("/api/telegram/webhook", %{
          "message" => %{
            "text" => "/start expired_or_invalid_token",
            "chat" => %{"id" => 12_345}
          }
        })

      # Controller returns 200 ok even for invalid tokens (Telegram expects 200)
      assert json_response(conn, 200)["ok"] == true
    end

    test "ignores non-start messages", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post("/api/telegram/webhook", %{
          "message" => %{
            "text" => "hello bot",
            "chat" => %{"id" => 12_345}
          }
        })

      assert json_response(conn, 200)["ok"] == true
    end

    test "handles updates without message field", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-telegram-bot-api-secret-token", @webhook_secret)
        |> post("/api/telegram/webhook", %{
          "update_id" => 123_456
        })

      assert json_response(conn, 200)["ok"] == true
    end
  end
end
