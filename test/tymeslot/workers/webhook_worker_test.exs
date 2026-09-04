defmodule Tymeslot.Workers.WebhookWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Meetings.Guests
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

    test "carries the meeting's guests to the endpoint" do
      meeting = insert(:meeting)
      webhook = insert(:webhook)

      {:ok, _guests} = Guests.create_for_meeting(meeting.id, ["colleague@example.com"])

      expect(Tymeslot.HTTPClientMock, :post, fn _url, body, _headers, _opts ->
        guests = body |> Jason.decode!() |> get_in(["data", "meeting", "guests"])

        assert [%{"email" => "colleague@example.com", "status" => "pending"}] = guests

        {:ok, %{status: 200, body: "ok"}}
      end)

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
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
      assert delivery.response_body == ~S("\xFF\xFE\xFD\xFC")
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

  # A subscriber's endpoint that is gone or rejects our credentials returns the
  # same status on every attempt. Retrying it burns the job's five tries and
  # ends in `Oban.PerformError`, which `ObanFailureAlerter` turns into an admin
  # email — paging an operator about a subscriber's own misconfiguration. Only
  # `{:discard, _}` avoids that, because an intentional discard emits `job:stop`
  # rather than the `job:exception` the alerter listens for.
  describe "perform/1 - retryability of HTTP failures" do
    setup do
      %{meeting: insert(:meeting), webhook: insert(:webhook, failure_count: 0)}
    end

    defp respond_with(status) do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: status, body: "irrelevant"}}
      end)
    end

    defp deliver(webhook, meeting) do
      perform_job(WebhookWorker, %{
        "webhook_id" => webhook.id,
        "event_type" => "meeting.cancelled",
        "meeting_id" => meeting.id
      })
    end

    test "discards rather than retries a 404", %{meeting: meeting, webhook: webhook} do
      respond_with(404)

      assert {:discard, "HTTP 404"} = deliver(webhook, meeting)
    end

    test "discards rather than retries a 401", %{meeting: meeting, webhook: webhook} do
      respond_with(401)

      assert {:discard, "HTTP 401"} = deliver(webhook, meeting)
    end

    test "discards rather than retries a 403", %{meeting: meeting, webhook: webhook} do
      respond_with(403)

      assert {:discard, "HTTP 403"} = deliver(webhook, meeting)
    end

    test "still records the failure when discarding", %{meeting: meeting, webhook: webhook} do
      # No retry follows, so this is the only chance to advance the circuit
      # breaker towards auto-disabling a permanently broken endpoint.
      respond_with(404)

      assert {:discard, _reason} = deliver(webhook, meeting)

      updated = Repo.get(WebhookSchema, webhook.id)
      assert updated.failure_count == 1
      assert updated.last_status =~ "failed"
    end

    test "still logs the delivery attempt when discarding", %{
      meeting: meeting,
      webhook: webhook
    } do
      respond_with(404)

      assert {:discard, _reason} = deliver(webhook, meeting)

      delivery = Repo.one(WebhookDeliverySchema)
      assert delivery.response_status == 404
    end

    test "keeps retrying a 429, which a later attempt may clear", %{
      meeting: meeting,
      webhook: webhook
    } do
      respond_with(429)

      assert {:error, {:http_error, 429}} = deliver(webhook, meeting)
    end

    test "keeps retrying a 503, which a later attempt may clear", %{
      meeting: meeting,
      webhook: webhook
    } do
      respond_with(503)

      assert {:error, {:http_error, 503}} = deliver(webhook, meeting)
    end
  end

  describe "snapshot/1" do
    test "captures the event-defining fields as JSON-safe values" do
      meeting =
        insert(:meeting,
          status: "awaiting_approval",
          approval_requested_at: ~U[2026-01-14 09:00:00Z],
          approval_deadline_at: ~U[2026-01-15 09:00:00Z]
        )

      snapshot = WebhookWorker.snapshot(meeting)

      assert snapshot["status"] == "awaiting_approval"
      assert snapshot["approval_requested_at"] == "2026-01-14T09:00:00Z"
      assert snapshot["approval_deadline_at"] == "2026-01-15T09:00:00Z"
      assert is_nil(snapshot["decline_reason"])
    end
  end

  describe "schedule_delivery/4" do
    test "carries the snapshot through to the enqueued job's args" do
      meeting_id = UUID.generate()
      snapshot = %{"status" => "awaiting_approval"}

      assert :ok =
               WebhookWorker.schedule_delivery(123, "meeting.requested", meeting_id, snapshot)

      assert_enqueued(
        worker: WebhookWorker,
        args: %{
          "webhook_id" => 123,
          "event_type" => "meeting.requested",
          "meeting_id" => meeting_id,
          "snapshot" => snapshot
        }
      )
    end

    test "omits the snapshot key entirely when none is given, same as schedule_delivery/3" do
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

      [job] = all_enqueued(worker: WebhookWorker)
      refute Map.has_key?(job.args, "snapshot")
    end
  end

  describe "perform/1 - replays the dispatch-time snapshot on retry" do
    test "reports the status the event asserted, not the meeting's current status" do
      meeting = insert(:meeting, status: "awaiting_approval")
      webhook = insert(:webhook)
      snapshot = WebhookWorker.snapshot(meeting)

      # Simulates the host declining the request before a retried delivery of
      # the original meeting.requested job runs.
      meeting
      |> Changeset.change(status: "cancelled", decline_reason: "Not a fit")
      |> Repo.update!()

      expect(Tymeslot.HTTPClientMock, :post, fn _url, body, _headers, _opts ->
        meeting_data = body |> Jason.decode!() |> get_in(["data", "meeting"])

        assert meeting_data["status"] == "awaiting_approval"
        refute Map.has_key?(meeting_data, "decline")

        {:ok, %{status: 200, body: "ok"}}
      end)

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.requested",
                 "meeting_id" => meeting.id,
                 "snapshot" => snapshot
               })
    end

    test "falls back to the live meeting for a job enqueued before snapshots existed" do
      meeting = insert(:meeting, status: "confirmed")
      webhook = insert(:webhook)

      expect_http_success()

      assert :ok =
               perform_job(WebhookWorker, %{
                 "webhook_id" => webhook.id,
                 "event_type" => "meeting.created",
                 "meeting_id" => meeting.id
               })
    end
  end
end

# Minimal access checker that always denies, used for the revocation test
defmodule Tymeslot.Workers.WebhookWorkerTest.DenyAccessChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: {:error, :insufficient_plan}
end
