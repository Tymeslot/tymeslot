defmodule TymeslotWeb.WebhookCompositionTest do
  @moduledoc """
  Composition tests for the Microsoft Graph Outlook Calendar webhook,
  focused on input-shape and rate-limit gaps the existing
  `outlook_calendar_webhook_controller_test.exs` does not pin.

  The existing file covers the happy path, batch handling, clientState
  verification, unknown subscriptions, and the plain-text validation
  challenge. It does not cover the edge paths that would surface
  as incidents on the user:

    * a non-printable validation token — an attacker probing the
      endpoint with binary noise would otherwise receive a 200 with
      the raw token echoed back, which could be framed into a
      content-type-confusion issue;
    * a notification whose shape parses but is missing the nested
      `resourceData.id` — left unpinned, a regression that touched
      `last_outlook_notification_at` here would make the "last
      received" timestamp meaningless (it would advance on every
      malformed Graph burst, masking real silence);
    * a valid notification arriving after the per-integration Hammer
      bucket is exhausted — the controller must still return 202 (Graph
      expects it) but must NOT enqueue `SyncOutlookCalendarWorker` and
      must NOT advance `last_outlook_notification_at`.

  Dropped from the plan with rationale:

    * Validation token > 256 bytes → 400 — the premise is contradicted
      by production code. The first `webhook/2` clause guards
      `byte_size(token) <= 256`; an oversize token fails the guard,
      falls through to the `_params` clause, and returns 202 (the
      notification-batch arm with no notifications to process). Graph
      does not treat 202 as a validation response, so subscription
      activation fails — the correct security outcome, just not a 400.

    * Outlook notification with `Oban.insert` failure →
      `touch_notification_timestamp` NOT called — the premise is
      contradicted by production code. `handle_valid_notification/2`
      at `outlook_calendar_webhook_controller.ex:131-134` calls
      `enqueue_sync/2` and then unconditionally calls
      `touch_notification_timestamp/1`. The Oban error is swallowed
      inside `enqueue_sync/2` and the timestamp still advances.
      Whether this is the desired behaviour is a product question
      (timestamp = "heard from Graph" vs. "successfully queued a
      sync"); either way, the current behaviour is "always touch" and
      pinning the opposite would lock in a fiction.

    * Outlook lifecycle missing `subscriptionId` / `lifecycleEvent` →
      202, no enqueue — covered at
      `outlook_lifecycle_controller_test.exs` ("missing value key" and
      "missing required fields" scenarios). Catch-all at
      `outlook_lifecycle_controller.ex:88` makes this a no-op that
      returns 202, already asserted.

    * Google webhook concurrent deliveries for same channel_id → at
      most one sync enqueued per delivery — the premise is confused.
      `GoogleCalendarWebhookController.webhook/2` has no in-controller
      deduplication; it enqueues exactly one
      `SyncGoogleCalendarWorker` per valid POST by construction. The
      interesting dedup semantics (duplicate in-flight syncs for the
      same integration) belong in Oban unique-job config, not in a
      webhook controller test.

    * Telegram webhook when `telegram_webhook_secret` is nil →
      consistent 403 — covered at `telegram_webhook_controller_test.exs`
      (nil/missing/mismatched secret → 403) together with the
      `telegram_enabled?` / `shared_bot_mode?` 404 path.
  """

  # async: false — tests exhaust Hammer's shared ETS bucket to exercise the
  # per-integration rate-limit arm; isolation requires sequential execution.
  use TymeslotWeb.ConnCase, async: false

  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :controllers
  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  describe "Outlook validationToken — non-printable bytes" do
    test "returns 400 and does not echo the token", %{conn: conn} do
      # Raw binary with a NUL byte — `String.printable?/1` rejects this
      # even though it is valid UTF-8 wire data. A regression that
      # removed the `String.printable?` guard would surface here as
      # either a 200 echoing the NUL byte (a content-type-confusion
      # vector) or a crash on the downstream plain-text encoder.
      non_printable = "token\x00with-nul"

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar?validationToken=#{URI.encode(non_printable)}")

      assert conn.status == 400
      assert conn.resp_body == ""
      refute_enqueued(worker: SyncOutlookCalendarWorker)
    end
  end

  describe "Outlook notification — missing resourceData.id" do
    test "logs and returns 202 without enqueuing or touching the notification timestamp",
         %{conn: conn} do
      # Seed an integration with a known last-notification timestamp so
      # we can prove it does not advance. `last_outlook_notification_at`
      # is the signal operators use to tell "Graph is silent" from
      # "Graph is firing but we're dropping payloads" — if a malformed
      # notification (one with a valid subscriptionId + clientState but
      # a nil resourceData.id) bumped this timestamp, we would lose the
      # ability to detect a subscription that has gone quiet.
      baseline_at = ~U[2026-01-01 00:00:00Z]

      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-no-resource",
          graph_client_state: "state-secret",
          last_outlook_notification_at: baseline_at
        )

      payload = %{
        "value" => [
          %{
            "subscriptionId" => integration.graph_subscription_id,
            "clientState" => integration.graph_client_state
            # resourceData intentionally omitted.
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar", payload)

      assert conn.status == 202
      refute_enqueued(worker: SyncOutlookCalendarWorker)

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert DateTime.compare(reloaded.last_outlook_notification_at, baseline_at) == :eq
    end
  end

  describe "Outlook notification — per-integration rate limit" do
    test "returns 202 and does not enqueue or touch the notification timestamp when rate limited",
         %{conn: conn} do
      # Pin a baseline timestamp so we can detect any unwanted advance.
      baseline_at = ~U[2026-01-01 00:00:00Z]

      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-rate-limited",
          graph_client_state: "state-rate-limited",
          last_outlook_notification_at: baseline_at
        )

      # Exhaust the per-integration Hammer bucket (61 hits > the 60-per-60s
      # limit) to guarantee the sliding-window check returns {:error,
      # :rate_limited} for this integration id regardless of timing jitter.
      for _i <- 1..61 do
        RateLimit.hit("calendar_webhook:#{integration.id}", 60_000, 60)
      end

      # Confirm the bucket is genuinely exhausted before the HTTP call.
      assert {:error, :rate_limited} =
               RateLimiter.check_calendar_webhook_rate_limit(integration.id)

      payload = %{
        "value" => [
          %{
            "subscriptionId" => integration.graph_subscription_id,
            "clientState" => integration.graph_client_state,
            "resourceData" => %{"id" => "event-graph-id-xyz"}
          }
        ]
      }

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/webhooks/outlook-calendar", payload)

      # Graph always gets 202; the rate-limit arm is transparent to the caller.
      assert conn.status == 202

      # No sync job must be queued when rate limited.
      refute_enqueued(worker: SyncOutlookCalendarWorker)

      # The "last heard from Graph" timestamp must not advance — if it did,
      # operators would lose the ability to detect a subscription gone quiet.
      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert DateTime.compare(reloaded.last_outlook_notification_at, baseline_at) == :eq
    end
  end
end
