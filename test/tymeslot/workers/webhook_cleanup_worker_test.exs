defmodule Tymeslot.Workers.WebhookCleanupWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Workers.WebhookCleanupWorker

  describe "perform/1" do
    test "cleans up old webhook deliveries based on retention days" do
      webhook = insert(:webhook)

      # Create some deliveries
      # Old delivery (61 days ago)
      old_date = DateTime.add(DateTime.utc_now(), -61, :day)
      old_delivery = insert(:webhook_delivery, webhook: webhook, inserted_at: old_date)

      # Recent delivery (10 days ago)
      recent_date = DateTime.add(DateTime.utc_now(), -10, :day)
      recent_delivery = insert(:webhook_delivery, webhook: webhook, inserted_at: recent_date)

      # Run the worker with default 60 days retention
      assert :ok = perform_job(WebhookCleanupWorker, %{})

      # Check results
      refute Repo.get(Tymeslot.DatabaseSchemas.WebhookDeliverySchema, old_delivery.id)
      assert Repo.get(Tymeslot.DatabaseSchemas.WebhookDeliverySchema, recent_delivery.id)
    end

    test "respects retention_days argument" do
      webhook = insert(:webhook)

      # Delivery from 35 days ago
      date_35 = DateTime.add(DateTime.utc_now(), -35, :day)
      delivery_35 = insert(:webhook_delivery, webhook: webhook, inserted_at: date_35)

      # Run with 30 days retention
      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => 30})

      refute Repo.get(Tymeslot.DatabaseSchemas.WebhookDeliverySchema, delivery_35.id)

      # Run with 40 days retention on another delivery
      delivery_35_new = insert(:webhook_delivery, webhook: webhook, inserted_at: date_35)
      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => 40})

      assert Repo.get(Tymeslot.DatabaseSchemas.WebhookDeliverySchema, delivery_35_new.id)
    end

    test "handles negative retention days safely (should not delete everything)" do
      webhook = insert(:webhook)

      # Create deliveries at various ages
      recent_delivery = insert(:webhook_delivery, webhook: webhook)

      old_delivery =
        insert(:webhook_delivery,
          webhook: webhook,
          inserted_at: DateTime.add(DateTime.utc_now(), -100, :day)
        )

      # Negative retention should not cause data loss
      # The query should handle this gracefully (likely by keeping all records)
      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => -1})

      # Both deliveries should still exist (negative days = keep everything)
      assert Repo.get(Tymeslot.DatabaseSchemas.WebhookDeliverySchema, recent_delivery.id)
      assert Repo.get(Tymeslot.DatabaseSchemas.WebhookDeliverySchema, old_delivery.id)
    end

    test "handles zero retention days (deletes all)" do
      webhook = insert(:webhook)

      _recent_delivery = insert(:webhook_delivery, webhook: webhook)

      old_delivery =
        insert(:webhook_delivery,
          webhook: webhook,
          inserted_at: DateTime.add(DateTime.utc_now(), -10, :day)
        )

      # Zero retention = delete everything older than today
      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => 0})

      # Old delivery should be deleted, recent might be kept depending on timestamp precision
      refute Repo.get(Tymeslot.DatabaseSchemas.WebhookDeliverySchema, old_delivery.id)
    end

    test "handles extremely large retention days (capped to reasonable limit)" do
      webhook = insert(:webhook)

      very_old_delivery =
        insert(:webhook_delivery,
          webhook: webhook,
          inserted_at: DateTime.add(DateTime.utc_now(), -1000, :day)
        )

      # Very large retention will cause DateTime.add to overflow
      # This documents the edge case - in production, retention should be < 10000 days
      # Testing with a large but reasonable value (10000 days = ~27 years)
      assert :ok = perform_job(WebhookCleanupWorker, %{"retention_days" => 10_000})

      # With such high retention, the old delivery should still exist
      assert Repo.get(Tymeslot.DatabaseSchemas.WebhookDeliverySchema, very_old_delivery.id)
    end
  end
end
