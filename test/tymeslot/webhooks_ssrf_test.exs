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
      # Literal private-IP redirect targets (127.0.0.1, 169.254.169.254) are
      # rejected by `UrlValidation`'s syntax-level check alone, before the
      # DNS resolver is ever consulted — a test built on one would keep
      # passing even if the per-hop `SsrfValidator.check/1` call were deleted
      # from `HttpDelivery.follow_redirect/7` entirely, since nothing else
      # in this test proves that call still happens. Substituting the DNS
      # resolver and redirecting to a hostname that only "resolves" private
      # according to the stub closes that gap: the redirect can only be
      # blocked if the hop is actually re-validated.
      setup_config(:tymeslot, :dns_resolver_module, Tymeslot.DnsResolverMock)
      :ok
    end

    test "blocks a redirect to a hostname that DNS-resolves to a private address" do
      stub(Tymeslot.DnsResolverMock, :resolve_public, fn url, _opts ->
        if String.contains?(url, "rebinding.example.com") do
          {:error, "URL resolves to a private or local network address"}
        else
          {:ok, [{93, 184, 216, 34}]}
        end
      end)

      expect(Tymeslot.HTTPClientMock, :post, 1, fn "https://example.com/webhook",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["https://rebinding.example.com/internal"]}
         }}
      end)

      assert {:error, message} =
               Webhooks.test_webhook_connection("https://example.com/webhook")

      # Specifically the redirect-hop rejection (`:blocked_redirect`), not
      # the generic initial-URL rejection (`:blocked_by_ssrf`) — the two map
      # to distinct messages in `Webhooks.map_test_connection_result/1`, so
      # this fails if the hop check stops running (the initial check alone
      # would never reach this message) or is replaced by a syntax-only check
      # that a bare hostname sails through.
      assert message =~ "redirected to a private or restricted address"
    end

    test "blocks a redirect to a hostname that DNS-resolves to the cloud metadata address" do
      stub(Tymeslot.DnsResolverMock, :resolve_public, fn url, _opts ->
        if String.contains?(url, "metadata.example.com") do
          {:error, "URL resolves to a private or local network address"}
        else
          {:ok, [{93, 184, 216, 34}]}
        end
      end)

      expect(Tymeslot.HTTPClientMock, :post, 1, fn "https://example.com/webhook",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["https://metadata.example.com/latest/meta-data/"]}
         }}
      end)

      assert {:error, message} =
               Webhooks.test_webhook_connection("https://example.com/webhook")

      assert message =~ "redirected to a private or restricted address"
    end
  end
end
