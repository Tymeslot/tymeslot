defmodule Tymeslot.Workers.RenewWebhookChannelsWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

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
    test "returns :ok when expiring Google channels exist" do
      insert(:calendar_integration,
        provider: "google",
        google_channel_id: "expiring-channel",
        google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
      )

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
    end
  end

  describe "perform/1 - expiring Outlook subscriptions" do
    test "returns :ok when expiring Outlook subscriptions exist" do
      insert(:calendar_integration,
        provider: "outlook",
        graph_subscription_id: "expiring-subscription",
        graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
      )

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
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
  end
end
