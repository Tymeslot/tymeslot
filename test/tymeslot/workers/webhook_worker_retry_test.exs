defmodule Tymeslot.Workers.WebhookWorkerRetryTest do
  @moduledoc """
  Which failed webhook deliveries are retried and for how long, and that a
  delivery the receiver already accepted is never posted a second time because its
  delivery log could not be written.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :webhooks

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

  describe "perform/1 - delivery log failure after a successful post" do
    # The receiver already has the event: a failed log write must neither fail
    # the job nor release the claim, or the retry would post it again. The
    # trigger fails every delivery-log insert for this test's transaction.
    test "does not post a delivered webhook again" do
      meeting = insert(:meeting)
      webhook = insert(:webhook, failure_count: 2)

      job =
        persisted_job(WebhookWorker, %{
          "webhook_id" => webhook.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        })

      fail_delivery_log_inserts()
      expect_http_success()

      try do
        WebhookWorker.perform(job)
      rescue
        Postgrex.Error -> :log_insert_raised
      end

      allow_delivery_log_inserts()

      assert :ok = WebhookWorker.perform(%{job | attempt: 2})
      assert Repo.aggregate(WebhookDeliverySchema, :count) == 0
    end

    test "counts the post as a success when the log insert returns an error" do
      meeting = insert(:meeting)
      webhook = insert(:webhook, failure_count: 2)

      job =
        persisted_job(WebhookWorker, %{
          "webhook_id" => webhook.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        })

      fail_delivery_log_inserts(as: :foreign_key)
      expect_http_success()

      assert :ok = WebhookWorker.perform(job)
      assert Repo.get!(WebhookSchema, webhook.id).failure_count == 0

      allow_delivery_log_inserts()
      assert :ok = WebhookWorker.perform(%{job | attempt: 2})
    end
  end

  describe "backoff/1" do
    test "spreads eight attempts over hours, so a receiver outage does not lose the event" do
      assert WebhookWorker.__opts__()[:max_attempts] == 8

      assert Enum.map(1..7, &WebhookWorker.backoff(%Oban.Job{attempt: &1})) ==
               [30, 120, 600, 1_800, 3_600, 10_800, 21_600]
    end

    test "caps the wait at six hours" do
      assert WebhookWorker.backoff(%Oban.Job{attempt: 20}) == 21_600
    end
  end

  # A trigger rejecting every delivery-log insert, rolled back with the test's
  # sandbox transaction. `as: :foreign_key` raises it as the webhook foreign
  # key violation the changeset declares, so the insert returns an error
  # instead of raising.
  defp fail_delivery_log_inserts(opts \\ []) do
    raise_clause =
      case Keyword.get(opts, :as) do
        :foreign_key ->
          "RAISE EXCEPTION 'rejected' USING ERRCODE = 'foreign_key_violation', " <>
            "CONSTRAINT = 'webhook_deliveries_webhook_id_fkey'"

        nil ->
          "RAISE EXCEPTION 'delivery log unavailable'"
      end

    Repo.query!("""
    CREATE FUNCTION test_reject_delivery_log() RETURNS trigger AS $$
    BEGIN #{raise_clause}; END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER test_reject_delivery_log BEFORE INSERT ON webhook_deliveries
    FOR EACH ROW EXECUTE FUNCTION test_reject_delivery_log()
    """)
  end

  defp allow_delivery_log_inserts do
    Repo.query!("DROP TRIGGER test_reject_delivery_log ON webhook_deliveries")
  end

  # A subscriber's endpoint that is gone, rejects our credentials or rejects
  # the request returns the same status on every attempt. Retrying it burns
  # the job's remaining tries, each recorded by error tracking as an
  # `Oban.PerformError` that can alert an operator about a subscriber's own
  # misconfiguration. Only `{:discard, _}` avoids that, because an intentional
  # discard emits `job:stop` rather than the `job:exception` error tracking
  # records.
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

    test "discards rather than retries a 400", %{meeting: meeting, webhook: webhook} do
      respond_with(400)

      assert {:discard, "HTTP 400"} = deliver(webhook, meeting)
    end

    test "discards rather than retries a 422", %{meeting: meeting, webhook: webhook} do
      respond_with(422)

      assert {:discard, "HTTP 422"} = deliver(webhook, meeting)
    end

    test "records a discarded 400 as one failure, as a retried 503 is", %{
      meeting: meeting,
      webhook: webhook
    } do
      respond_with(400)

      assert {:discard, _reason} = deliver(webhook, meeting)
      assert Repo.get(WebhookSchema, webhook.id).failure_count == 1
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

    test "keeps retrying a 408, which a later attempt may clear", %{
      meeting: meeting,
      webhook: webhook
    } do
      respond_with(408)

      assert {:error, {:http_error, 408}} = deliver(webhook, meeting)
    end

    test "keeps retrying a transport error, which a later attempt may clear", %{
      meeting: meeting,
      webhook: webhook
    } do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :econnrefused} = deliver(webhook, meeting)
    end

    test "keeps retrying a 429, which a later attempt may clear", %{
      meeting: meeting,
      webhook: webhook
    } do
      respond_with(429)

      assert {:error, {:http_error, 429}} = deliver(webhook, meeting)
    end

    test "keeps retrying a 425, which a later attempt may clear", %{
      meeting: meeting,
      webhook: webhook
    } do
      respond_with(425)

      assert {:error, {:http_error, 425}} = deliver(webhook, meeting)
      assert Repo.get(WebhookSchema, webhook.id).failure_count == 1
    end

    test "counts a 503 followed by a discarded 4xx as one failure", %{
      meeting: meeting,
      webhook: webhook
    } do
      job =
        persisted_job(WebhookWorker, %{
          "webhook_id" => webhook.id,
          "event_type" => "meeting.cancelled",
          "meeting_id" => meeting.id
        })

      respond_with(503)
      assert {:error, {:http_error, 503}} = WebhookWorker.perform(job)

      respond_with(400)
      assert {:discard, "HTTP 400"} = WebhookWorker.perform(%{job | attempt: 2})

      assert Repo.get(WebhookSchema, webhook.id).failure_count == 1
    end

    test "keeps retrying a 503, which a later attempt may clear", %{
      meeting: meeting,
      webhook: webhook
    } do
      respond_with(503)

      assert {:error, {:http_error, 503}} = deliver(webhook, meeting)
    end
  end
end
