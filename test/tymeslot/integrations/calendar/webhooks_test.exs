defmodule Tymeslot.Integrations.Calendar.WebhooksTest do
  # Not async: the enqueue failure test replaces `Oban` globally with :meck.
  use Tymeslot.DataCase, async: false

  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Integrations.Calendar.Webhooks
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimit
  alias Tymeslot.Workers.ReregisterOutlookSubscriptionWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  defp exhaust_calendar_webhook_rate_limit(integration) do
    for _i <- 1..61 do
      RateLimit.hit("calendar_webhook:#{integration.id}", 60_000, 60)
    end
  end

  defp reload(integration), do: Repo.get!(CalendarIntegrationSchema, integration.id)

  defp change_notification(integration, attrs \\ %{}) do
    Map.merge(
      %{
        "subscriptionId" => integration.graph_subscription_id,
        "clientState" => integration.graph_client_state,
        "resourceData" => %{"id" => "event-#{System.unique_integer([:positive])}"}
      },
      attrs
    )
  end

  defp lifecycle_event(integration, event_type, attrs \\ %{}) do
    Map.merge(
      %{
        "subscriptionId" => integration.graph_subscription_id,
        "clientState" => integration.graph_client_state,
        "lifecycleEvent" => event_type
      },
      attrs
    )
  end

  describe "handle_google_notification/2" do
    setup do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-#{System.unique_integer([:positive])}",
          google_channel_secret: "secret-#{System.unique_integer([:positive])}",
          last_google_notification_at: nil
        )

      %{integration: integration}
    end

    test "enqueues a sync for the channel's integration and records the notification",
         %{integration: integration} do
      assert :ok =
               Webhooks.handle_google_notification(
                 integration.google_channel_id,
                 integration.google_channel_secret
               )

      assert [job] = all_enqueued(worker: SyncGoogleCalendarWorker)
      assert job.args == %{"calendar_integration_id" => integration.id}
      assert %DateTime{} = reload(integration).last_google_notification_at
    end

    test "ignores an unknown channel" do
      assert {:error, :not_found} =
               Webhooks.handle_google_notification("channel-unknown", "any-token")

      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    @tag capture_log: true
    test "ignores a notification whose token does not match", %{integration: integration} do
      assert {:error, :invalid_token} =
               Webhooks.handle_google_notification(integration.google_channel_id, "wrong")

      refute_enqueued(worker: SyncGoogleCalendarWorker)
      assert reload(integration).last_google_notification_at == nil
    end

    @tag capture_log: true
    test "ignores a missing token", %{integration: integration} do
      assert {:error, :invalid_token} =
               Webhooks.handle_google_notification(integration.google_channel_id, "")

      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    @tag capture_log: true
    test "never matches an integration without a stored secret" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_channel_id: "channel-no-secret",
          google_channel_secret: nil
        )

      assert {:error, :invalid_token} =
               Webhooks.handle_google_notification(integration.google_channel_id, "")

      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    @tag capture_log: true
    test "drops the notification once the integration is rate limited",
         %{integration: integration} do
      exhaust_calendar_webhook_rate_limit(integration)

      assert {:error, :rate_limited} =
               Webhooks.handle_google_notification(
                 integration.google_channel_id,
                 integration.google_channel_secret
               )

      refute_enqueued(worker: SyncGoogleCalendarWorker)
      assert reload(integration).last_google_notification_at == nil
    end

    @tag capture_log: true
    test "does not record the notification when the sync cannot be enqueued",
         %{integration: integration} do
      :meck.new(Oban, [:passthrough])
      :meck.expect(Oban, :insert, fn _job -> {:error, :queue_not_available} end)

      try do
        assert {:error, :enqueue_failed} =
                 Webhooks.handle_google_notification(
                   integration.google_channel_id,
                   integration.google_channel_secret
                 )
      after
        :meck.unload(Oban)
      end

      assert reload(integration).last_google_notification_at == nil
    end
  end

  describe "handle_outlook_notifications/1" do
    setup do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-#{System.unique_integer([:positive])}",
          graph_client_state: "state-#{System.unique_integer([:positive])}",
          last_outlook_notification_at: nil
        )

      %{integration: integration}
    end

    test "enqueues a sync of the named event and records the notification",
         %{integration: integration} do
      notification = change_notification(integration, %{"resourceData" => %{"id" => "event-1"}})

      assert :ok = Webhooks.handle_outlook_notifications([notification])

      assert [job] = all_enqueued(worker: SyncOutlookCalendarWorker)

      assert job.args == %{
               "calendar_integration_id" => integration.id,
               "graph_resource_id" => "event-1"
             }

      assert %DateTime{} = reload(integration).last_outlook_notification_at
    end

    @tag capture_log: true
    test "skips a notification whose clientState does not match", %{integration: integration} do
      Webhooks.handle_outlook_notifications([
        change_notification(integration, %{"clientState" => "wrong"})
      ])

      refute_enqueued(worker: SyncOutlookCalendarWorker)
      assert reload(integration).last_outlook_notification_at == nil
    end

    @tag capture_log: true
    test "skips a notification without resourceData", %{integration: integration} do
      notification = Map.delete(change_notification(integration), "resourceData")

      Webhooks.handle_outlook_notifications([notification])

      refute_enqueued(worker: SyncOutlookCalendarWorker)
      assert reload(integration).last_outlook_notification_at == nil
    end

    test "skips unknown subscriptions and notifications without one", %{integration: integration} do
      Webhooks.handle_outlook_notifications([
        change_notification(integration, %{"subscriptionId" => "sub-unknown"}),
        Map.delete(change_notification(integration), "subscriptionId")
      ])

      refute_enqueued(worker: SyncOutlookCalendarWorker)
    end

    @tag capture_log: true
    test "skips notifications once the integration is rate limited",
         %{integration: integration} do
      exhaust_calendar_webhook_rate_limit(integration)

      Webhooks.handle_outlook_notifications([change_notification(integration)])

      refute_enqueued(worker: SyncOutlookCalendarWorker)
    end

    test "acts on at most 50 notifications from one payload", %{integration: integration} do
      notifications = for _i <- 1..51, do: change_notification(integration)

      Webhooks.handle_outlook_notifications(notifications)

      assert length(all_enqueued(worker: SyncOutlookCalendarWorker)) == 50
    end

    @tag capture_log: true
    test "does not record the notification when the sync cannot be enqueued",
         %{integration: integration} do
      :meck.new(Oban, [:passthrough])
      :meck.expect(Oban, :insert, fn _job -> {:error, :queue_not_available} end)

      try do
        Webhooks.handle_outlook_notifications([change_notification(integration)])
      after
        :meck.unload(Oban)
      end

      # The timestamp is what `DeadChannelAlertWorker` reads to spot a silent
      # channel, so a run of failed inserts must not read as a healthy one.
      assert reload(integration).last_outlook_notification_at == nil
    end

    test "acts on the notifications in a payload that also carries junk entries",
         %{integration: integration} do
      notification = change_notification(integration, %{"resourceData" => %{"id" => "event-1"}})

      assert :ok =
               Webhooks.handle_outlook_notifications([7, "not-a-notification", notification])

      assert [job] = all_enqueued(worker: SyncOutlookCalendarWorker)
      assert job.args["graph_resource_id"] == "event-1"
    end

    test "acts on the notifications in a payload that also carries non-string subscription ids",
         %{integration: integration} do
      # The subscription-id lookup cannot cast a number or a map, so these
      # used to raise an Ecto.Query.CastError out of the public endpoint.
      notification = change_notification(integration, %{"resourceData" => %{"id" => "event-1"}})

      assert :ok =
               Webhooks.handle_outlook_notifications([
                 %{"subscriptionId" => 1, "clientState" => "x"},
                 %{"subscriptionId" => %{"id" => "a"}},
                 notification
               ])

      assert [job] = all_enqueued(worker: SyncOutlookCalendarWorker)
      assert job.args["graph_resource_id"] == "event-1"
    end

    test "ignores a notification value that is not a list", %{integration: integration} do
      assert :ok = Webhooks.handle_outlook_notifications("not-a-list")

      refute_enqueued(worker: SyncOutlookCalendarWorker)
      assert reload(integration).last_outlook_notification_at == nil
    end
  end

  describe "handle_outlook_lifecycle_notifications/1" do
    setup do
      integration =
        insert(:calendar_integration,
          provider: "outlook",
          graph_subscription_id: "sub-lifecycle-#{System.unique_integer([:positive])}",
          graph_client_state: "state-#{System.unique_integer([:positive])}"
        )

      %{integration: integration}
    end

    @tag capture_log: true
    test "reauthorizationRequired refreshes the token, then re-registers the subscription",
         %{integration: integration} do
      assert :ok =
               Webhooks.handle_outlook_lifecycle_notifications([
                 lifecycle_event(integration, "reauthorizationRequired")
               ])

      assert [refresh] = all_enqueued(worker: TokenRefreshJob)
      assert refresh.args == %{"integration_id" => integration.id}

      assert [reregistration] = all_enqueued(worker: ReregisterOutlookSubscriptionWorker)
      assert reregistration.args == %{"calendar_integration_id" => integration.id}
      assert_in_delta DateTime.diff(reregistration.scheduled_at, DateTime.utc_now()), 30, 5
    end

    @tag capture_log: true
    test "subscriptionRemoved re-registers the subscription straight away",
         %{integration: integration} do
      Webhooks.handle_outlook_lifecycle_notifications([
        lifecycle_event(integration, "subscriptionRemoved")
      ])

      assert [reregistration] = all_enqueued(worker: ReregisterOutlookSubscriptionWorker)
      assert reregistration.args == %{"calendar_integration_id" => integration.id}
      assert_in_delta DateTime.diff(reregistration.scheduled_at, DateTime.utc_now()), 0, 5
      refute_enqueued(worker: TokenRefreshJob)
    end

    @tag capture_log: true
    test "acts only on the first event per subscription", %{integration: integration} do
      Webhooks.handle_outlook_lifecycle_notifications([
        lifecycle_event(integration, "subscriptionRemoved"),
        lifecycle_event(integration, "reauthorizationRequired")
      ])

      assert_enqueued(worker: ReregisterOutlookSubscriptionWorker)
      refute_enqueued(worker: TokenRefreshJob)
    end

    @tag capture_log: true
    test "ignores an event whose clientState does not match", %{integration: integration} do
      Webhooks.handle_outlook_lifecycle_notifications([
        lifecycle_event(integration, "reauthorizationRequired", %{"clientState" => "wrong"})
      ])

      refute_enqueued(worker: TokenRefreshJob)
      refute_enqueued(worker: ReregisterOutlookSubscriptionWorker)
    end

    @tag capture_log: true
    test "ignores unknown subscriptions and unrecognised event types",
         %{integration: integration} do
      Webhooks.handle_outlook_lifecycle_notifications([
        lifecycle_event(integration, "reauthorizationRequired", %{
          "subscriptionId" => "sub-unknown"
        }),
        lifecycle_event(integration, "missed")
      ])

      refute_enqueued(worker: TokenRefreshJob)
      refute_enqueued(worker: ReregisterOutlookSubscriptionWorker)
    end

    @tag capture_log: true
    test "ignores events once the integration is rate limited", %{integration: integration} do
      exhaust_calendar_webhook_rate_limit(integration)

      Webhooks.handle_outlook_lifecycle_notifications([
        lifecycle_event(integration, "subscriptionRemoved")
      ])

      refute_enqueued(worker: ReregisterOutlookSubscriptionWorker)
    end

    @tag capture_log: true
    test "acts on the events in a payload that also carries junk entries",
         %{integration: integration} do
      assert :ok =
               Webhooks.handle_outlook_lifecycle_notifications([
                 7,
                 "not-an-event",
                 lifecycle_event(integration, "subscriptionRemoved")
               ])

      assert_enqueued(
        worker: ReregisterOutlookSubscriptionWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    @tag capture_log: true
    test "acts on the events in a payload that also carries non-string subscription ids",
         %{integration: integration} do
      assert :ok =
               Webhooks.handle_outlook_lifecycle_notifications([
                 %{"subscriptionId" => 1, "lifecycleEvent" => "subscriptionRemoved"},
                 %{"subscriptionId" => ["a"], "lifecycleEvent" => "subscriptionRemoved"},
                 lifecycle_event(integration, "subscriptionRemoved")
               ])

      assert [reregistration] = all_enqueued(worker: ReregisterOutlookSubscriptionWorker)
      assert reregistration.args == %{"calendar_integration_id" => integration.id}
    end

    test "ignores a lifecycle value that is not a list" do
      assert :ok =
               Webhooks.handle_outlook_lifecycle_notifications(%{
                 "lifecycleEvent" => "subscriptionRemoved"
               })

      refute_enqueued(worker: ReregisterOutlookSubscriptionWorker)
    end
  end
end
