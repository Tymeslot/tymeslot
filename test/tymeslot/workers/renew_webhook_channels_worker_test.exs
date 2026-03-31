defmodule Tymeslot.Workers.RenewWebhookChannelsWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Workers.RenewWebhookChannelsWorker

  setup :verify_on_exit!

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

      # No mock expectations — the API must not be called
      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
    end
  end

  describe "perform/1 - expiring Google channels" do
    test "renews an expiring Google channel and returns :ok" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "expiring-channel",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:ok, integration}
      end)

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
    end

    test "returns :ok and skips gracefully when WEBHOOK_BASE_URL is not configured" do
      insert(:calendar_integration,
        provider: "google",
        google_channel_id: "expiring-no-url",
        google_channel_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
      )

      expect(GoogleCalendarAPIMock, :register_push_channel, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
    end
  end

  describe "perform/1 - expiring Outlook subscriptions" do
    test "renews an expiring Outlook subscription and returns :ok" do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "expiring-subscription",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
        )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:ok, integration}
      end)

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
    end

    test "returns :ok and skips gracefully when WEBHOOK_BASE_URL is not configured for Outlook" do
      insert(:calendar_integration,
        provider: "outlook",
        graph_subscription_id: "expiring-sub-no-url",
        graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 12, :hour)
      )

      expect(OutlookCalendarAPIMock, :register_graph_subscription, fn _integration ->
        {:error, :webhook_base_url_not_configured}
      end)

      assert :ok = perform_job(RenewWebhookChannelsWorker, %{})
    end
  end
end
