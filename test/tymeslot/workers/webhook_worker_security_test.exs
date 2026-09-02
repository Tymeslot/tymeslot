defmodule Tymeslot.Workers.WebhookWorkerSecurityTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Webhooks.WebhookDeliverySchema
  alias Tymeslot.Webhooks.WebhookSchema
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      environment: :test
    )

    :ok
  end

  describe "perform/1 - security" do
    test "sends the webhook token and a current timestamp as request headers" do
      meeting = insert(:meeting)
      user = insert(:user)

      # Insert webhook with encrypted token
      {:ok, webhook} =
        %WebhookSchema{}
        |> WebhookSchema.changeset(%{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"],
          is_active: true,
          user_id: user.id
        })
        |> Repo.insert()

      # The token is generated automatically on insert
      webhook = WebhookSchema.decrypt_token(webhook)
      # Generated tokens carry a "ts_" prefix and 24 random bytes in base64.
      assert webhook.webhook_token =~ ~r"\Ats_[A-Za-z0-9+/]{32}\z"

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, headers, _opts ->
        # Verify token header is present and correct
        token_header = Enum.find(headers, fn {key, _value} -> key == "X-Tymeslot-Token" end)
        assert token_header, "Expected X-Tymeslot-Token header"
        {_key, value} = token_header
        assert value == webhook.webhook_token

        # Verify timestamp header is present
        timestamp_header =
          Enum.find(headers, fn {key, _value} -> key == "X-Tymeslot-Timestamp" end)

        assert timestamp_header, "Expected X-Tymeslot-Timestamp header"

        {_timestamp_key, timestamp} = timestamp_header

        # Verify timestamp is ISO8601 format and recent
        {:ok, ts, _utc_offset} = DateTime.from_iso8601(timestamp)
        diff = DateTime.diff(DateTime.utc_now(), ts, :second)
        assert diff < 60, "Timestamp should be recent (within 60 seconds)"

        {:ok, %{status: 200, body: "OK"}}
      end)

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "blocks delivery and logs the attempt when the URL targets a private network in production" do
      with_config(:tymeslot, environment: :prod)

      meeting = insert(:meeting)
      # AWS metadata endpoint (common SSRF target)
      # Use HTTPS to trigger the private network check instead of the HTTPS check
      webhook = insert(:webhook, url: "https://169.254.169.254/latest/meta-data")

      # HTTP client should never be called
      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: "Should not reach here"}}
      end)

      assert {:discard, :blocked_by_ssrf} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      # Verify delivery was logged with error
      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery, "Expected delivery log to exist"
      assert delivery.error_message =~ "blocked_by_ssrf"
      refute delivery.delivered_at
    end

    test "allows private-range URLs in non-production environments" do
      with_config(:tymeslot, environment: :test)

      meeting = insert(:meeting)
      webhook = insert(:webhook, url: "http://169.254.169.254/test")

      expect_http_success()

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    # A public host cannot legitimately redirect a webhook delivery to the
    # loopback interface — that is the exact SSRF bypass we want to close.
    # The second HTTP call must never happen, because the redirect target
    # is re-validated by check_ssrf/1 before the re-POST.
    test "refuses to follow a redirect that points at loopback" do
      with_config(:tymeslot, environment: :prod)

      meeting = insert(:meeting)
      webhook = insert(:webhook, url: "https://example.com/webhook")

      # Exactly one HTTP call: the initial POST returning a 301 to loopback.
      # If the worker follows the redirect, a second call (to 127.0.0.1) would
      # happen and this expectation would fail.
      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["http://127.0.0.1:8080/internal"]}
         }}
      end)

      assert {:discard, :blocked_redirect} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery, "Expected delivery log to exist"
      assert delivery.error_message =~ "blocked_redirect"
      refute delivery.delivered_at
    end

    test "refuses to follow a redirect that points at the link-local range" do
      with_config(:tymeslot, environment: :prod)

      meeting = insert(:meeting)
      webhook = insert(:webhook, url: "https://example.com/webhook")

      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 302,
           body: "",
           headers: %{"location" => ["http://169.254.169.254/latest/meta-data/"]}
         }}
      end)

      assert {:discard, :blocked_redirect} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery.error_message =~ "blocked_redirect"
      refute delivery.delivered_at
    end

    # The redirect guard must not break legitimate webhook relays that bounce
    # a request from one public host to another (e.g. provider-side DNS
    # migration). Both hops validate cleanly, so the second POST completes.
    test "follows a legitimate public-to-public redirect" do
      # Use :test env so the initial and redirected URL only need to pass URL-
      # structure validation — the goal here is to prove the redirect loop
      # delivers the final response, not to re-test DNS filtering.
      with_config(:tymeslot, environment: :test)

      meeting = insert(:meeting)
      webhook = insert(:webhook, url: "https://example.com/webhook")

      # First call returns 301 to a new public URL; second call returns 200.
      Tymeslot.HTTPClientMock
      |> expect(:post, fn "https://example.com/webhook", _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["https://other.example.com/webhook"]}
         }}
      end)
      |> expect(:get, fn "https://other.example.com/webhook", _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "OK"}}
      end)

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery.response_status == 200
      assert delivery.delivered_at
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Issue 5 — DNS-rebinding via redirect target hostname
  # ──────────────────────────────────────────────────────────────────────────
  describe "perform/1 - DNS-rebinding protection on redirect targets" do
    test "blocks a redirect to a hostname that DNS-resolves to a private IP" do
      # Run in production mode so both UrlValidation AND DnsResolution run.
      with_config(:tymeslot, environment: :prod)
      # Substitute the DNS resolver so we can simulate a rebinding response
      # without actually controlling DNS.
      with_config(:tymeslot, :dns_resolver_module, Tymeslot.DnsResolverMock)

      meeting = insert(:meeting)
      webhook = insert(:webhook, url: "https://example.com/webhook")

      # The redirect target looks public at URL-parse time but "resolves" to
      # a private address according to our stubbed DNS resolver.
      stub(Tymeslot.DnsResolverMock, :resolve_public, fn url, _opts ->
        if String.contains?(url, "rebinding.example.com") do
          {:error, "URL resolves to a private or local network address"}
        else
          {:ok, [{93, 184, 216, 34}]}
        end
      end)

      expect(Tymeslot.HTTPClientMock, :post, 1, fn _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 301,
           body: "",
           headers: %{"location" => ["https://rebinding.example.com/internal"]}
         }}
      end)

      assert {:discard, :blocked_redirect} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery, "Expected a delivery log row for the blocked attempt"
      assert delivery.error_message =~ "blocked_redirect"
    end
  end
end
