defmodule Tymeslot.Workers.WebhookCleanupWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.WebhookDeliverySchema
  alias Tymeslot.DatabaseSchemas.WebhookEventSchema
  alias Tymeslot.Workers.WebhookCleanupWorker

  describe "perform/1 - outgoing webhook delivery cleanup" do
    test "removes delivery records older than the retention period" do
      webhook = insert(:webhook)

      old_date = DateTime.add(DateTime.utc_now(), -61, :day)
      old_delivery = insert(:webhook_delivery, webhook: webhook, inserted_at: old_date)

      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)
      recent_delivery = insert(:webhook_delivery, webhook: webhook, inserted_at: recent_date)

      assert :ok = perform_job(WebhookCleanupWorker, %{})

      refute Repo.get(WebhookDeliverySchema, old_delivery.id)
      assert Repo.get(WebhookDeliverySchema, recent_delivery.id)
    end

    test "respects the retention_days argument" do
      webhook = insert(:webhook)

      date_35 = DateTime.add(DateTime.utc_now(), -35, :day)
      delivery_35 = insert(:webhook_delivery, webhook: webhook, inserted_at: date_35)

      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => 30})
      refute Repo.get(WebhookDeliverySchema, delivery_35.id)

      delivery_35_new = insert(:webhook_delivery, webhook: webhook, inserted_at: date_35)
      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => 40})
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

      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => -1})

      # Negative retention is treated as a guard: no records are deleted
      assert Repo.get(WebhookDeliverySchema, recent_delivery.id)
      assert Repo.get(WebhookDeliverySchema, old_delivery.id)
    end

    test "zero retention days removes everything older than today" do
      webhook = insert(:webhook)

      _recent_delivery = insert(:webhook_delivery, webhook: webhook)

      old_delivery =
        insert(:webhook_delivery,
          webhook: webhook,
          inserted_at: DateTime.add(DateTime.utc_now(), -10, :day)
        )

      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => 0})

      refute Repo.get(WebhookDeliverySchema, old_delivery.id)
    end

    test "very large retention days keeps all records" do
      webhook = insert(:webhook)

      very_old_delivery =
        insert(:webhook_delivery,
          webhook: webhook,
          inserted_at: DateTime.add(DateTime.utc_now(), -1000, :day)
        )

      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => 10_000})

      assert Repo.get(WebhookDeliverySchema, very_old_delivery.id)
    end
  end

  describe "perform/1 - incoming Stripe webhook event cleanup" do
    # Use insert_all to bypass Ecto's autogenerate for inserted_at, which would
    # override any value we set via Repo.insert!/1 with the current timestamp.
    defp insert_webhook_event(stripe_event_id, dt) do
      truncated = DateTime.truncate(dt, :second)
      naive = DateTime.to_naive(truncated)

      {1, [%{id: id}]} =
        Repo.insert_all(
          "webhook_events",
          [
            %{
              stripe_event_id: stripe_event_id,
              event_type: "customer.subscription.updated",
              processed_at: truncated,
              inserted_at: naive
            }
          ],
          returning: [:id]
        )

      id
    end

    test "removes Stripe event records older than the retention period" do
      old_date = DateTime.add(DateTime.utc_now(), -91, :day)
      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)

      old_id = insert_webhook_event("evt_old_#{System.unique_integer()}", old_date)
      recent_id = insert_webhook_event("evt_recent_#{System.unique_integer()}", recent_date)

      assert :ok = perform_job(WebhookCleanupWorker, %{})

      refute Repo.get(WebhookEventSchema, old_id)
      assert Repo.get(WebhookEventSchema, recent_id)
    end

    test "respects the stripe_event_retention_days argument" do
      date_45 = DateTime.add(DateTime.utc_now(), -45, :day)
      event_id = insert_webhook_event("evt_45d_#{System.unique_integer()}", date_45)

      # With 30-day retention the 45-day-old event should be removed
      assert :ok = perform_job(WebhookCleanupWorker, %{"stripe_event_retention_days" => 30})
      refute Repo.get(WebhookEventSchema, event_id)
    end

    test "outgoing delivery cleanup and Stripe event cleanup run together in a single job" do
      webhook = insert(:webhook)
      old_date = DateTime.add(DateTime.utc_now(), -91, :day)

      old_delivery = insert(:webhook_delivery, webhook: webhook, inserted_at: old_date)
      old_event_id = insert_webhook_event("evt_combined_#{System.unique_integer()}", old_date)

      assert :ok = perform_job(WebhookCleanupWorker, %{})

      refute Repo.get(WebhookDeliverySchema, old_delivery.id)
      refute Repo.get(WebhookEventSchema, old_event_id)
    end
  end
end
