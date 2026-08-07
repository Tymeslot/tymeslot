defmodule Tymeslot.Telegram.BotSetupTest do
  @moduledoc """
  Coverage for shared-bot webhook registration at boot.

  `BotSetup.register_webhook/0` is called from `Tymeslot.Application` and had
  no tests at all. It is the single point that decides whether the shared
  Telegram bot can receive anything: if it silently returns `{:error, …}` on
  deploy, every shared-bot integration goes dark and the only trace is a log
  line nobody is watching.

  The retry ladder is the part worth pinning. It exists because the Telegram
  API is routinely unreachable for a few seconds during a deploy, so
  "transient failure then success" is the *expected* path, not an edge case —
  and it is exactly the path that regresses silently if the recursion is ever
  rewired to stop retrying.
  """

  use ExUnit.Case, async: false

  @moduletag :telegram
  @moduletag :integrations
  @moduletag :unit

  import Mox

  alias Tymeslot.Telegram.BotSetup

  setup :verify_on_exit!

  setup do
    original = [
      token: Application.get_env(:tymeslot, :telegram_bot_token),
      secret: Application.get_env(:tymeslot, :telegram_webhook_secret),
      delay: Application.get_env(:tymeslot, :telegram_webhook_retry_delay_ms)
    ]

    Application.put_env(:tymeslot, :telegram_bot_token, "123456:test-bot-token")
    Application.put_env(:tymeslot, :telegram_webhook_secret, "test-webhook-secret")
    Application.put_env(:tymeslot, :telegram_webhook_retry_delay_ms, 1)

    on_exit(fn ->
      restore(:telegram_bot_token, original[:token])
      restore(:telegram_webhook_secret, original[:secret])
      restore(:telegram_webhook_retry_delay_ms, original[:delay])
    end)

    :ok
  end

  describe "configuration guards" do
    test "returns :missing_config when the bot token is absent" do
      Application.delete_env(:tymeslot, :telegram_bot_token)

      assert BotSetup.register_webhook() == {:error, :missing_config}
    end

    test "returns :missing_config when the webhook secret is absent" do
      Application.delete_env(:tymeslot, :telegram_webhook_secret)

      assert BotSetup.register_webhook() == {:error, :missing_config}
    end

    test "never calls Telegram when configuration is incomplete" do
      Application.delete_env(:tymeslot, :telegram_bot_token)

      # No `expect` is set, so `verify_on_exit!` fails the test if the HTTP
      # boundary is touched at all. A registration attempt with no token would
      # otherwise burn the full retry ladder against a request that cannot
      # succeed.
      assert BotSetup.register_webhook() == {:error, :missing_config}
    end
  end

  describe "successful registration" do
    test "returns :ok on a 2xx response" do
      expect_set_webhook(fn -> ok_response() end)

      assert BotSetup.register_webhook() == :ok
    end

    test "sends the configured secret and a webhook URL on the app's own host" do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :post, fn url, body, _headers, _opts ->
        send(test_pid, {:telegram_call, url, Jason.decode!(body)})
        ok_response()
      end)

      assert BotSetup.register_webhook() == :ok

      assert_receive {:telegram_call, url, payload}

      assert url =~ "123456:test-bot-token/setWebhook"
      assert payload["secret_token"] == "test-webhook-secret"
      assert payload["url"] =~ "/api/telegram/webhook"
    end

    test "is idempotent — a second registration is another plain success" do
      expect_set_webhook(2, fn -> ok_response() end)

      assert BotSetup.register_webhook() == :ok
      assert BotSetup.register_webhook() == :ok
    end
  end

  describe "retry ladder" do
    test "retries after a transport error and succeeds" do
      responses = [
        fn -> {:error, %Mint.TransportError{reason: :timeout}} end,
        fn -> ok_response() end
      ]

      expect_sequence(responses)

      assert BotSetup.register_webhook() == :ok
    end

    test "retries after a non-2xx response and succeeds" do
      responses = [
        fn -> {:ok, %{status: 502, body: "bad gateway"}} end,
        fn -> ok_response() end
      ]

      expect_sequence(responses)

      assert BotSetup.register_webhook() == :ok
    end

    test "gives up after five attempts and surfaces the last error" do
      # @max_retries is 4, so the initial attempt plus four retries.
      expect_set_webhook(5, fn -> {:ok, %{status: 500, body: "server error"}} end)

      assert BotSetup.register_webhook() == {:error, {:http_error, 500}}
    end

    test "gives up after five attempts on a persistent transport error" do
      expect_set_webhook(5, fn -> {:error, %Mint.TransportError{reason: :econnrefused}} end)

      # `Telegram.API` stringifies the transport reason before it gets here.
      assert BotSetup.register_webhook() == {:error, ":econnrefused"}
    end
  end

  defp ok_response, do: {:ok, %{status: 200, body: ~s({"ok":true})}}

  defp expect_set_webhook(times \\ 1, response_fun) do
    expect(Tymeslot.HTTPClientMock, :post, times, fn _url, _body, _headers, _opts ->
      response_fun.()
    end)
  end

  defp expect_sequence(response_funs) do
    Enum.each(response_funs, fn response_fun ->
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        response_fun.()
      end)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore(key, value), do: Application.put_env(:tymeslot, key, value)
end
