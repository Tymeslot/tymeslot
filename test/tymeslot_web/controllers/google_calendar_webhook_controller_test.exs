defmodule TymeslotWeb.GoogleCalendarWebhookControllerTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :controllers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  describe "webhook/2 - valid request" do
    test "enqueues SyncGoogleCalendarWorker and returns 200", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-abc-123",
          google_channel_secret: "secret-token-xyz"
        )

      conn =
        conn
        |> put_req_header("x-goog-channel-id", integration.google_channel_id)
        |> put_req_header("x-goog-channel-token", integration.google_channel_secret)
        |> post("/webhooks/google-calendar")

      assert conn.status == 200

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "updates last_google_notification_at on valid request", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-ts-update",
          google_channel_secret: "secret-ts-token",
          last_google_notification_at: nil
        )

      conn
      |> put_req_header("x-goog-channel-id", integration.google_channel_id)
      |> put_req_header("x-goog-channel-token", integration.google_channel_secret)
      |> post("/webhooks/google-calendar")

      updated = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert updated.last_google_notification_at != nil
    end
  end

  describe "webhook/2 - invalid token" do
    test "returns 200 without enqueuing a job when token is wrong", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-bad-token",
          google_channel_secret: "the-real-secret"
        )

      conn =
        conn
        |> put_req_header("x-goog-channel-id", integration.google_channel_id)
        |> put_req_header("x-goog-channel-token", "wrong-secret")
        |> post("/webhooks/google-calendar")

      assert conn.status == 200
      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    test "returns 200 without enqueuing a job when token header is missing", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-no-token",
          google_channel_secret: "some-secret"
        )

      conn =
        conn
        |> put_req_header("x-goog-channel-id", integration.google_channel_id)
        |> post("/webhooks/google-calendar")

      assert conn.status == 200
      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end
  end

  describe "webhook/2 - unknown channel" do
    test "returns 200 without enqueuing a job when channel ID is unknown", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-goog-channel-id", "nonexistent-channel-id")
        |> put_req_header("x-goog-channel-token", "any-token")
        |> post("/webhooks/google-calendar")

      assert conn.status == 200
      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    test "returns 200 without enqueuing a job when channel ID header is missing", %{conn: conn} do
      conn = post(conn, "/webhooks/google-calendar")

      assert conn.status == 200
      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end
  end

  describe "webhook/2 - rate limiting" do
    @tag capture_log: true
    test "stops enqueuing jobs after rate limit is exceeded", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-rate-limit",
          google_channel_secret: "secret-rate-limit"
        )

      # Send 61 requests — limit is 60/min
      for _i <- 1..61 do
        conn
        |> put_req_header("x-goog-channel-id", integration.google_channel_id)
        |> put_req_header("x-goog-channel-token", integration.google_channel_secret)
        |> post("/webhooks/google-calendar")
      end

      # Should have at most 60 enqueued jobs, not 61
      jobs = all_enqueued(worker: SyncGoogleCalendarWorker)
      assert length(jobs) <= 60
    end

    test "always returns 200 even when rate limited", %{conn: conn} do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-rate-200",
          google_channel_secret: "secret-rate-200"
        )

      # Exhaust the rate limit (hit beyond the limit to avoid boundary races
      # in Hammer's sliding window ETS backend)
      for _i <- 1..61 do
        RateLimit.hit("calendar_webhook:#{integration.id}", 60_000, 60)
      end

      # Verify it's actually exhausted
      assert {:error, :rate_limited} =
               RateLimiter.check_calendar_webhook_rate_limit(integration.id)

      conn =
        conn
        |> put_req_header("x-goog-channel-id", integration.google_channel_id)
        |> put_req_header("x-goog-channel-token", integration.google_channel_secret)
        |> post("/webhooks/google-calendar")

      assert conn.status == 200
    end
  end

  describe "webhook/2 - Oban enqueue failure" do
    test "returns 200 and logs error when Oban.insert fails", %{conn: conn} do
      import ExUnit.CaptureLog

      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-oban-fail",
          google_channel_secret: "secret-oban-fail"
        )

      :meck.new(Oban, [:passthrough])
      :meck.expect(Oban, :insert, fn _job -> {:error, :queue_not_available} end)

      try do
        log =
          capture_log(fn ->
            conn =
              conn
              |> put_req_header("x-goog-channel-id", integration.google_channel_id)
              |> put_req_header("x-goog-channel-token", integration.google_channel_secret)
              |> post("/webhooks/google-calendar")

            assert conn.status == 200
          end)

        assert log =~ "Failed to enqueue SyncGoogleCalendarWorker"
        refute_enqueued(worker: SyncGoogleCalendarWorker)
      after
        :meck.unload(Oban)
      end
    end
  end
end
