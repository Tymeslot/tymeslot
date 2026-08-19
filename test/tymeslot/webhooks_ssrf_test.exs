defmodule Tymeslot.WebhooksSsrfTest do
  @moduledoc """
  SSRF protection for the webhook "test connection" probe.

  Split out of `Tymeslot.WebhooksTest`, which had grown past the module size
  limit. These tests cover one self-contained concern: the probe must refuse a
  private or restricted address, and must re-check every redirect hop rather
  than following them blind.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :security

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Webhooks

  setup do
    setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
    :ok
  end

  # ============================================================================
  # SSRF Protection (existing tests)
  # ============================================================================

  describe "test_webhook_connection/2 - SSRF protection" do
    setup do
      setup_config(:tymeslot, :environment, :prod)
      :ok
    end

    test "blocks requests to private IP addresses in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://192.168.1.1/webhook")
      assert message =~ "Private"
    end

    test "blocks requests to localhost in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://localhost/webhook")
      assert message =~ "Private"
    end

    test "blocks HTTP URLs in production" do
      assert {:error, message} =
               Webhooks.test_webhook_connection("http://example.com/webhook")

      assert message =~ "HTTPS"
    end

    test "blocks requests to loopback address in production" do
      assert {:error, message} = Webhooks.test_webhook_connection("https://127.0.0.1/webhook")
      assert message =~ "Private"
    end
  end

  describe "test_webhook_connection/2 - SSRF protection on redirects" do
    setup :verify_on_exit!

    setup do
      setup_config(:tymeslot, :environment, :prod)
      :ok
    end

    test "blocks a redirect to a private address even when the initial URL is public" do
      # The initial URL passes the syntax/scheme check, but the probe must not
      # follow a same-request redirect to a private/loopback address blind —
      # every hop is re-validated (mirrors the fix applied to the custom video
      # provider's reachability probe).
      expect(Tymeslot.HTTPClientMock, :post, 1, fn "https://example.com/webhook",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["http://127.0.0.1:8080/internal"]}
         }}
      end)

      assert {:error, _message} =
               Webhooks.test_webhook_connection("https://example.com/webhook")
    end

    test "blocks a redirect to the cloud metadata endpoint" do
      expect(Tymeslot.HTTPClientMock, :post, 1, fn "https://example.com/webhook",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["http://169.254.169.254/latest/meta-data/"]}
         }}
      end)

      assert {:error, _message} =
               Webhooks.test_webhook_connection("https://example.com/webhook")
    end
  end
end
