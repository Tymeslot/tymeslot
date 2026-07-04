defmodule Tymeslot.Workers.DataRetentionWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Analytics.EventSchema
  alias Tymeslot.Slack.SlackDeliverySchema
  alias Tymeslot.Telegram.TelegramDeliverySchema
  alias Tymeslot.Webhooks.WebhookDeliverySchema
  alias Tymeslot.Webhooks.WebhookEventSchema
  alias Tymeslot.Workers.DataRetentionWorker

  describe "perform/1 - outgoing webhook delivery cleanup" do
    test "removes delivery records older than the retention period" do
      webhook = insert(:webhook)

      old_date = DateTime.add(DateTime.utc_now(), -61, :day)
      old_delivery = insert(:webhook_delivery, webhook: webhook, inserted_at: old_date)

      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)
      recent_delivery = insert(:webhook_delivery, webhook: webhook, inserted_at: recent_date)

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(WebhookDeliverySchema, old_delivery.id)
      assert Repo.get(WebhookDeliverySchema, recent_delivery.id)
    end

    test "respects the retention_days argument" do
      webhook = insert(:webhook)

      date_35 = DateTime.add(DateTime.utc_now(), -35, :day)
      delivery_35 = insert(:webhook_delivery, webhook: webhook, inserted_at: date_35)

      assert :ok = perform_job(DataRetentionWorker, %{"retention_days" => 30})
      refute Repo.get(WebhookDeliverySchema, delivery_35.id)

      delivery_35_new = insert(:webhook_delivery, webhook: webhook, inserted_at: date_35)
      assert :ok = perform_job(DataRetentionWorker, %{"retention_days" => 40})
      assert Repo.get(WebhookDeliverySchema, delivery_35_new.id)
    end

    test "guards against negative retention days to prevent unintended bulk deletion" do
      webhook = insert(:webhook)

      recent_delivery = insert(:webhook_delivery, webhook: webhook)

      old_delivery =
        insert(:webhook_delivery,
          webhook: webhook,
          inserted_at: DateTime.add(DateTime.utc_now(), -100, :day)
        )

      assert :ok = perform_job(DataRetentionWorker, %{"retention_days" => -1})

      # Negative retention is treated as a guard: no records are deleted
      assert Repo.get(WebhookDeliverySchema, recent_delivery.id)
      assert Repo.get(WebhookDeliverySchema, old_delivery.id)
    end

    test "zero retention days is a safe no-op and deletes nothing" do
      webhook = insert(:webhook)

      recent_delivery = insert(:webhook_delivery, webhook: webhook)

      old_delivery =
        insert(:webhook_delivery,
          webhook: webhook,
          inserted_at: DateTime.add(DateTime.utc_now(), -10, :day)
        )

      assert :ok = perform_job(DataRetentionWorker, %{"retention_days" => 0})

      # Zero is treated as a guard, like negative: a misconfigured
      # `retention_days: 0` can never wipe the whole table.
      assert Repo.get(WebhookDeliverySchema, recent_delivery.id)
      assert Repo.get(WebhookDeliverySchema, old_delivery.id)
    end

    test "very large retention days keeps all records" do
      webhook = insert(:webhook)

      very_old_delivery =
        insert(:webhook_delivery,
          webhook: webhook,
          inserted_at: DateTime.add(DateTime.utc_now(), -1000, :day)
        )

      assert :ok = perform_job(DataRetentionWorker, %{"retention_days" => 10_000})

      assert Repo.get(WebhookDeliverySchema, very_old_delivery.id)
    end
  end

  describe "perform/1 - incoming Stripe webhook event cleanup" do
    # Use insert_all to bypass Ecto's autogenerate for inserted_at, which would
    # override any value we set via Repo.insert!/1 with the current timestamp.
    defp insert_webhook_event(stripe_event_id, dt, opts \\ []) do
      truncated = DateTime.truncate(dt, :second)

      base_attrs = %{
        stripe_event_id: stripe_event_id,
        event_type: "customer.subscription.updated",
        processed_at: truncated,
        inserted_at: truncated
      }

      attrs =
        case Keyword.get(opts, :payload) do
          nil -> base_attrs
          payload -> Map.put(base_attrs, :payload, payload)
        end

      {1, [%{id: id}]} =
        Repo.insert_all("webhook_events", [attrs], returning: [:id])

      id
    end

    test "nullifies payloads older than 30 days but keeps the row" do
      old_date = DateTime.add(DateTime.utc_now(), -31, :day)
      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)
      payload = %{"type" => "invoice.paid", "data" => %{"amount" => 1000}}

      old_id =
        insert_webhook_event("evt_old_payload_#{System.unique_integer()}", old_date,
          payload: payload
        )

      recent_id =
        insert_webhook_event("evt_recent_payload_#{System.unique_integer()}", recent_date,
          payload: payload
        )

      assert :ok = perform_job(DataRetentionWorker, %{})

      old_event = Repo.get(WebhookEventSchema, old_id)
      assert old_event, "row should still exist"
      assert is_nil(old_event.payload), "payload should be nullified"

      recent_event = Repo.get(WebhookEventSchema, recent_id)
      assert recent_event.payload == payload, "recent payload should be preserved"
    end

    test "respects the payload_retention_days argument" do
      date_15 = DateTime.add(DateTime.utc_now(), -15, :day)
      payload = %{"type" => "invoice.paid"}

      event_id =
        insert_webhook_event("evt_15d_payload_#{System.unique_integer()}", date_15,
          payload: payload
        )

      # With 10-day retention the 15-day-old payload should be nullified
      assert :ok = perform_job(DataRetentionWorker, %{"payload_retention_days" => 10})

      event = Repo.get(WebhookEventSchema, event_id)
      assert is_nil(event.payload)
    end

    test "removes Stripe event records older than the retention period" do
      old_date = DateTime.add(DateTime.utc_now(), -91, :day)
      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)

      old_id = insert_webhook_event("evt_old_#{System.unique_integer()}", old_date)
      recent_id = insert_webhook_event("evt_recent_#{System.unique_integer()}", recent_date)

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(WebhookEventSchema, old_id)
      assert Repo.get(WebhookEventSchema, recent_id)
    end

    test "respects the stripe_event_retention_days argument" do
      date_45 = DateTime.add(DateTime.utc_now(), -45, :day)
      event_id = insert_webhook_event("evt_45d_#{System.unique_integer()}", date_45)

      # With 30-day retention the 45-day-old event should be removed
      assert :ok = perform_job(DataRetentionWorker, %{"stripe_event_retention_days" => 30})
      refute Repo.get(WebhookEventSchema, event_id)
    end

    test "outgoing delivery cleanup and Stripe event cleanup run together in a single job" do
      webhook = insert(:webhook)
      old_date = DateTime.add(DateTime.utc_now(), -91, :day)

      old_delivery = insert(:webhook_delivery, webhook: webhook, inserted_at: old_date)
      old_event_id = insert_webhook_event("evt_combined_#{System.unique_integer()}", old_date)

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(WebhookDeliverySchema, old_delivery.id)
      refute Repo.get(WebhookEventSchema, old_event_id)
    end
  end

  describe "perform/1 - Slack delivery log cleanup" do
    test "removes Slack delivery rows older than 60 days, keeps recent ones" do
      integration = insert(:slack_integration)
      old_date = DateTime.add(DateTime.utc_now(), -61, :day)
      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)

      old = insert(:slack_delivery, integration: integration, inserted_at: old_date)
      recent = insert(:slack_delivery, integration: integration, inserted_at: recent_date)

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(SlackDeliverySchema, old.id)
      assert Repo.get(SlackDeliverySchema, recent.id)
    end

    test "respects the slack_delivery_retention_days argument" do
      integration = insert(:slack_integration)
      date_45 = DateTime.add(DateTime.utc_now(), -45, :day)

      delivery = insert(:slack_delivery, integration: integration, inserted_at: date_45)

      assert :ok = perform_job(DataRetentionWorker, %{"slack_delivery_retention_days" => 30})
      refute Repo.get(SlackDeliverySchema, delivery.id)
    end
  end

  describe "perform/1 - Telegram delivery log cleanup" do
    test "removes Telegram delivery rows older than 60 days, keeps recent ones" do
      integration = insert(:telegram_integration)
      old_date = DateTime.add(DateTime.utc_now(), -61, :day)
      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)

      old = insert(:telegram_delivery, integration: integration, inserted_at: old_date)
      recent = insert(:telegram_delivery, integration: integration, inserted_at: recent_date)

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(TelegramDeliverySchema, old.id)
      assert Repo.get(TelegramDeliverySchema, recent.id)
    end

    test "respects the telegram_delivery_retention_days argument" do
      integration = insert(:telegram_integration)
      date_45 = DateTime.add(DateTime.utc_now(), -45, :day)

      delivery = insert(:telegram_delivery, integration: integration, inserted_at: date_45)

      assert :ok = perform_job(DataRetentionWorker, %{"telegram_delivery_retention_days" => 30})
      refute Repo.get(TelegramDeliverySchema, delivery.id)
    end
  end

  describe "perform/1 - analytics event cleanup" do
    defp insert_analytics_event(inserted_at) do
      Repo.insert!(%EventSchema{
        event_type: "page_view",
        path: "/#{System.unique_integer([:positive])}",
        visitor_hash: "v#{System.unique_integer([:positive])}",
        inserted_at: inserted_at
      })
    end

    test "removes analytics events older than 90 days, keeps recent ones" do
      old = insert_analytics_event(DateTime.add(DateTime.utc_now(), -91, :day))
      recent = insert_analytics_event(DateTime.add(DateTime.utc_now(), -30, :day))

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(EventSchema, old.id)
      assert Repo.get(EventSchema, recent.id)
    end

    test "respects the analytics_event_retention_days argument" do
      event = insert_analytics_event(DateTime.add(DateTime.utc_now(), -45, :day))

      assert :ok = perform_job(DataRetentionWorker, %{"analytics_event_retention_days" => 30})
      refute Repo.get(EventSchema, event.id)
    end
  end
end
