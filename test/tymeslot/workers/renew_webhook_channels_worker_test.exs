defmodule Tymeslot.Workers.RenewWebhookChannelsWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.RenewWebhookChannelsWorker

  describe "perform/1 - no expiring integrations" do
    test "returns :ok when there are no expiring Google channels or Outlook subscriptions" do
      # No integrations inserted - both lists will be empty
      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
    end

    test "returns :ok when Google integrations exist but are not expiring soon" do
      # Channel expires far in the future (well beyond the 48h window)
      insert(:calendar_integration,
        provider: "google",
        google_channel_id: "non-expiring-channel",
        google_channel_expires_at: DateTime.add(DateTime.utc_now(), 72, :hour)
      )

      # No jobs should be scheduled
      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
      refute_enqueued(worker: RenewWebhookChannelsWorker, args: %{"provider" => "google"})
    end
  end

  describe "perform/1 - expiring Google channels" do
    test "enqueues a per-integration renewal job for an expiring Google channel" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "expiring-channel",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      assert_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => integration.id, "provider" => "google"}
      )
    end
  end

  describe "perform/1 - integrations awaiting reauthorisation" do
    test "does not renew an expiring Google channel for a flagged integration" do
      # A flagged integration cannot succeed at renewal until its owner
      # reconnects, so re-registering its channel every day only burns retries
      # and raises a daily permanent-failure alert.
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "expiring-channel",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour),
          needs_reauth: true
        )

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      refute_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "does not renew an expiring Outlook subscription for a flagged integration" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "expiring-subscription",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour),
          needs_reauth: true
        )

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      refute_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "perform/1 - expiring Outlook subscriptions" do
    test "enqueues a per-integration renewal job for an expiring Outlook subscription" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "expiring-subscription",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      assert_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => integration.id, "provider" => "outlook"}
      )
    end
  end

  describe "perform/1 - per-integration renewal" do
    setup :verify_on_exit!

    test "renews a Google channel via the API module" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "renewal-target",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:ok, integration}
      end)

      assert :ok =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "google"
               })
    end

    test "renews an Outlook subscription via the API module" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "renewal-target",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:ok, integration}
      end)

      assert :ok =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "outlook"
               })
    end

    test "returns :ok when WEBHOOK_BASE_URL is not configured for Google" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "no-url-channel",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "google"
               })
    end

    test "returns :ok when WEBHOOK_BASE_URL is not configured for Outlook" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "no-url-sub",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "outlook"
               })
    end

    test "surfaces Google provider HTTP errors as {:error, _} so Oban retries" do
      # The provider API has four documented non-retryable responses — 401
      # (token revoked), 403 (forbidden), 500 (server blew up), and any
      # transport failure. The worker collapses them all to `{:error, reason}`
      # so Oban's retry machinery (max_attempts: 3) gets a chance to recover.
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "failing-channel",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:error, {:http_error, 500}}
      end)

      assert {:error, {:http_error, 500}} =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "google"
               })
    end

    test "surfaces Outlook provider HTTP errors as {:error, _} so Oban retries" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "failing-sub",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, {:http_error, 401}}
      end)

      assert {:error, {:http_error, 401}} =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "outlook"
               })
    end

    test "surfaces Google three-element {:error, type, reason} responses so Oban retries" do
      # Transport/network failures surface as a three-element tuple
      # (e.g. `{:error, :network_error, "…"}`). The worker must collapse these
      # to `{:error, reason}` rather than crashing with a CaseClauseError.
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "network-failing-channel",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:error, :network_error, "HTTP 503 (see logs for details)"}
      end)

      assert {:error, "HTTP 503 (see logs for details)"} =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "google"
               })
    end

    test "surfaces Outlook three-element {:error, type, reason} responses so Oban retries" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "network-failing-sub",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :network_error, "HTTP 503 (see logs for details)"}
      end)

      assert {:error, "HTTP 503 (see logs for details)"} =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "outlook"
               })
    end

    test "discards and flags for reconnection when the Google calendar is gone" do
      # The channel endpoint is calendar-scoped, so a 404 means the booking
      # calendar was deleted at the provider. Retrying cannot recover it, and
      # exhausting the retries raises a permanent-failure admin alert daily.
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "orphaned-channel",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour),
          needs_reauth: false
        )

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:error, :not_found, "Calendar not found"}
      end)

      assert {:discard, "Booking calendar not found — user action required"} =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "google"
               })

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth
      assert reloaded.sync_error =~ "no longer exists"
    end

    test "discards and flags for reconnection when the Outlook calendar is gone" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "orphaned-sub",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour),
          needs_reauth: false
        )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :not_found, "Calendar not found"}
      end)

      assert {:discard, "Booking calendar not found — user action required"} =
               perform_job(RenewWebhookChannelsWorker, %{
                 "calendar_integration_id" => integration.id,
                 "provider" => "outlook"
               })

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth
      assert reloaded.sync_error =~ "no longer exists"
    end
  end

  describe "perform/1 - push registration backfill (WEBHOOK_BASE_URL set)" do
    setup do
      previous = Application.get_env(:tymeslot, :webhook_base_url)
      Application.put_env(:tymeslot, :webhook_base_url, "https://tymeslot.example")

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:tymeslot, :webhook_base_url)
          value -> Application.put_env(:tymeslot, :webhook_base_url, value)
        end
      end)

      :ok
    end

    test "schedules registration for a Google integration that has no channel yet" do
      integration = insert(:calendar_integration, provider: "google", google_channel_id: nil)

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      assert_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => integration.id, "provider" => "google"}
      )
    end

    test "schedules registration for an Outlook integration that has no subscription yet" do
      integration =
        insert(:calendar_integration, provider: "outlook", graph_subscription_id: nil)

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      assert_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => integration.id, "provider" => "outlook"}
      )
    end

    test "skips integrations awaiting reauthorisation" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: nil,
          needs_reauth: true
        )

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      refute_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "skips inactive integrations" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: nil,
          is_active: false
        )

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      refute_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end
  end

  describe "perform/1 - push registration backfill (WEBHOOK_BASE_URL unset)" do
    setup do
      previous = Application.get_env(:tymeslot, :webhook_base_url)
      Application.delete_env(:tymeslot, :webhook_base_url)

      on_exit(fn ->
        if previous, do: Application.put_env(:tymeslot, :webhook_base_url, previous)
      end)

      :ok
    end

    test "does not backfill channel-less integrations when push is disabled" do
      google = insert(:calendar_integration, provider: "google", google_channel_id: nil)
      outlook = insert(:calendar_integration, provider: "outlook", graph_subscription_id: nil)

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})

      refute_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => google.id}
      )

      refute_enqueued(
        worker: RenewWebhookChannelsWorker,
        args: %{"calendar_integration_id" => outlook.id}
      )
    end
  end
end
