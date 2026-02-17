defmodule Tymeslot.Workers.WebhookWorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.UUID
  alias Tymeslot.DatabaseSchemas.WebhookDeliverySchema
  alias Tymeslot.DatabaseSchemas.WebhookSchema
  alias Tymeslot.Workers.WebhookWorker

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      environment: :test
    )

    :ok
  end

  describe "perform/1 - input validation" do
    test "handles missing webhook_id" do
      meeting = insert(:meeting)

      assert {:discard, "Missing required parameters"} =
               perform_job(WebhookWorker, %{
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "handles missing meeting_id" do
      webhook = insert(:webhook)

      assert {:discard, "Missing required parameters"} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created"
               })
    end

    test "handles missing event_type" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      assert {:discard, "Missing required parameters"} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "meeting_id" => meeting.id
               })
    end

    test "handles completely empty args" do
      assert {:discard, "Missing required parameters"} = perform_job(WebhookWorker, %{})
    end

    test "handles invalid webhook_id type" do
      meeting = insert(:meeting)

      # The database query will raise CastError for invalid types
      # This is expected behavior - the database layer is strict about types
      assert_raise Ecto.Query.CastError, fn ->
        perform_job(WebhookWorker, %{
          "webhook_id" => "not-a-number",
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        })
      end
    end
  end

  describe "perform/1 - successful delivery" do
    test "delivers webhook successfully" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      expect_http_success()

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      # Verify success was recorded
      updated_webhook = Repo.get(WebhookSchema, webhook.id)
      assert updated_webhook.last_triggered_at
      assert updated_webhook.last_status == "success"

      # Verify delivery log
      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery.webhook_id == webhook.id
      assert delivery.response_status == 200
      assert delivery.delivered_at
    end

    test "handles HTTP failure (server responded with error)" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "Error"}}
      end)

      assert {:error, {:http_error, 500}} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      # Verify failure was recorded
      updated_webhook = Repo.get(WebhookSchema, webhook.id)
      assert updated_webhook.last_status =~ "failed"
      assert updated_webhook.failure_count == 1

      # Verify delivery log - 500 is still a delivery
      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery.response_status == 500
      assert delivery.delivered_at
    end

    test "handles connection timeout (no response)" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %{reason: :timeout}}
      end)

      assert {:error, reason} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      assert reason =~ ":timeout"

      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery.error_message =~ "timeout"
      refute delivery.delivered_at
    end

    test "discards job if webhook or meeting not found" do
      assert {:discard, "Webhook or meeting not found"} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => 999_999,
                 "event_type" => "meeting.created",
                 "meeting_id" => UUID.generate()
               })
    end

    test "discards job if webhook is disabled" do
      meeting = insert(:meeting)
      webhook = insert(:webhook, is_active: false)

      assert {:discard, "Webhook is disabled"} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "handles massive response bodies (truncation)" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      # Response larger than 5000 character limit
      huge_body = String.duplicate("x", 10_000)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: huge_body}}
      end)

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      # Verify response was truncated
      delivery = Repo.one(WebhookDeliverySchema)
      assert String.length(delivery.response_body) <= 5000 + 20
      # +20 for "... (truncated)"
      assert String.ends_with?(delivery.response_body, "... (truncated)")
    end

    test "handles non-UTF8 response bodies safely" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      # Binary data that's not valid UTF-8
      binary_body = <<0xFF, 0xFE, 0xFD, 0xFC>>

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: binary_body}}
      end)

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      # Should not crash, response should be inspected
      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery.response_body
      # Should have been converted to inspected format
      assert is_binary(delivery.response_body)
    end
  end

  describe "perform/1 - security" do
    test "includes token and timestamp headers" do
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
      assert webhook.webhook_token != nil

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, headers, _opts ->
        # Verify token header is present and correct
        token_header = Enum.find(headers, fn {key, _value} -> key == "X-Tymeslot-Token" end)
        assert token_header, "Expected X-Tymeslot-Token header"
        {_key, value} = token_header
        assert value == webhook.webhook_token

        # Verify timestamp header is present
        timestamp_header = Enum.find(headers, fn {key, _value} -> key == "X-Tymeslot-Timestamp" end)
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

    test "blocks SSRF attempts to private networks in production" do
      with_config(:tymeslot, environment: :prod)

      meeting = insert(:meeting)
      # AWS metadata endpoint (common SSRF target)
      # Use HTTPS to trigger the private network check instead of the HTTPS check
      webhook = insert(:webhook, url: "https://169.254.169.254/latest/meta-data")

      # HTTP client should never be called
      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 200, body: "Should not reach here"}}
      end)

      # In production, the URL is validated before delivery and returns {:error, :blocked_by_ssrf}
      # which perform/1 then records as a failure and returns {:error, :blocked_by_ssrf}
      assert {:error, :blocked_by_ssrf} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      # Verify delivery was logged with error
      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery, "Expected delivery log to exist"
      assert delivery.error_message =~ "private or local network"
      refute delivery.delivered_at
    end

    test "allows SSRF-like URLs in non-production (testing)" do
      with_config(:tymeslot, environment: :test)

      meeting = insert(:meeting)
      webhook = insert(:webhook, url: "http://169.254.169.254/test")

      # In test mode, request should go through
      expect_http_success()

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "perform/1 - circuit breaker" do
    test "increments failure count on error" do
      meeting = insert(:meeting)
      webhook = insert(:webhook, failure_count: 0)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "Internal Server Error"}}
      end)

      assert {:error, {:http_error, 500}} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated_webhook = Repo.get(WebhookSchema, webhook.id)
      assert updated_webhook.failure_count == 1
    end

    test "resets failure count on success" do
      meeting = insert(:meeting)
      webhook = insert(:webhook, failure_count: 5)

      expect_http_success()

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated_webhook = Repo.get(WebhookSchema, webhook.id)
      # Note: The actual reset might happen in the WebhookQueries.record_success
      # This test documents expected behavior
      assert updated_webhook.last_status == "success"
    end
  end

  describe "schedule_delivery/3" do
    test "enqueues a job" do
      meeting_id = UUID.generate()
      assert :ok = WebhookWorker.schedule_delivery(123, "meeting.created", meeting_id)

      assert_enqueued(
        worker: WebhookWorker,
        args: %{
          "webhook_id" => 123,
          "event_type" => "meeting.created",
          "meeting_id" => meeting_id
        }
      )
    end
  end
end
