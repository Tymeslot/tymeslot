defmodule Tymeslot.Workers.WebhookWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers

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
    test "discards job when webhook_id is missing" do
      meeting = insert(:meeting)

      assert {:discard, "Missing required parameters"} =
               perform_job(WebhookWorker, %{
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end

    test "discards job when meeting_id is missing" do
      webhook = insert(:webhook)

      assert {:discard, "Missing required parameters"} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created"
               })
    end

    test "discards job when event_type is missing" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      assert {:discard, "Missing required parameters"} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "meeting_id" => meeting.id
               })
    end

    test "discards job with completely empty args" do
      assert {:discard, "Missing required parameters"} = perform_job(WebhookWorker, %{})
    end
  end

  describe "perform/1 - successful delivery" do
    test "delivers webhook successfully and records the outcome" do
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

    test "records the failure when the remote endpoint responds with a 5xx error" do
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

    test "records the failure and does not set delivered_at when the connection times out" do
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

      assert inspect(reason) =~ "timeout"

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

    test "truncates very large response bodies to avoid database bloat" do
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

      delivery = Repo.one(WebhookDeliverySchema)
      assert String.length(delivery.response_body) <= 5000 + 20
      # +20 for "... (truncated)"
      assert String.ends_with?(delivery.response_body, "... (truncated)")
    end

    test "handles non-UTF8 response bodies without crashing" do
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

      # Should not crash, response should be stored in an inspected format
      delivery = Repo.one(WebhookDeliverySchema)
      assert is_binary(delivery.response_body)
    end
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
      assert webhook.webhook_token != nil

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
  end

  describe "perform/1 - circuit breaker" do
    test "increments the failure count on each delivery error" do
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

    test "resets failure count to zero on a successful delivery" do
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
      assert updated_webhook.failure_count == 0
      assert updated_webhook.last_status == "success"
    end

    test "automatically disables the webhook after 10 consecutive failures" do
      meeting = insert(:meeting)
      # Webhook already has 9 failures; this delivery is the 10th
      webhook = insert(:webhook, failure_count: 9)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 500, body: "Persistent failure"}}
      end)

      assert {:error, {:http_error, 500}} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })

      updated_webhook = Repo.get(WebhookSchema, webhook.id)
      assert updated_webhook.failure_count == 10
      refute updated_webhook.is_active
      assert updated_webhook.disabled_at
      assert updated_webhook.disabled_reason =~ "Too many consecutive failures"
    end

    test "discards the job when feature access is revoked between scheduling and execution" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      # Simulate the user's plan being revoked after the job was scheduled
      with_config(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Workers.WebhookWorkerTest.DenyAccessChecker
      )

      # HTTP client must not be called; the job should be discarded before reaching delivery
      expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts ->
        flunk("HTTP client should not be called when access is revoked")
      end)

      assert {:discard, "Insufficient plan"} =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "schedule_delivery/3" do
    test "enqueues an Oban job with the correct arguments" do
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

# Minimal access checker that always denies, used for the revocation test
defmodule Tymeslot.Workers.WebhookWorkerTest.DenyAccessChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: {:error, :insufficient_plan}
end
