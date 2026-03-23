defmodule Tymeslot.WebhooksTest do
  use Tymeslot.DataCase, async: false

  @moduletag :security

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Webhooks

  describe "test_webhook_connection/2 - SSRF protection" do
    setup do
      setup_config(:tymeslot, :environment, :prod)
      :ok
    end

    test "blocks requests to private IP addresses in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://192.168.1.1/webhook")
      assert message =~ "private"
    end

    test "blocks requests to localhost in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://localhost/webhook")
      assert message =~ "private"
    end

    test "blocks HTTP URLs in production" do
      assert {:error, message} =
               Webhooks.test_webhook_connection("http://example.com/webhook")

      assert message =~ "HTTPS"
    end

    test "blocks requests to loopback address in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://127.0.0.1/webhook")
      assert message =~ "private"
    end
  end
end
