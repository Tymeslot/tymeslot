defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypesTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  describe "registry completeness" do
    test "every registered type has a format_message/2 clause that does not fall through to the fallback" do
      for {type, _config} <- AlertTypes.registered_types() do
        message = AlertTypes.format_message(type, %{})

        refute message == "Alert: #{type}",
               "#{type} falls through to the generic fallback — add a format_message/2 clause"
      end
    end

    test "registered_types/0 returns a map with category and severity for each entry" do
      for {type, config} <- AlertTypes.registered_types() do
        assert is_binary(config.category),
               "#{type} missing :category"

        assert config.severity in [:info, :warning, :error],
               "#{type} has invalid :severity #{inspect(config.severity)}"
      end
    end
  end

  describe "format_message/2 — per-type output" do
    test ":unhandled_webhook includes event type and ID" do
      msg =
        AlertTypes.format_message(:unhandled_webhook, %{
          event_type: "charge.failed",
          event_id: "evt_123"
        })

      assert msg =~ "charge.failed"
      assert msg =~ "evt_123"
    end

    test ":refund_processed includes user_id and amount" do
      msg = AlertTypes.format_message(:refund_processed, %{user_id: 42, total_refunded: 5000})
      assert msg =~ "42"
      assert msg =~ "5000"
    end

    test ":unlinked_refund includes charge_id and amount" do
      msg =
        AlertTypes.format_message(:unlinked_refund, %{charge_id: "ch_abc", total_refunded: 3000})

      assert msg =~ "ch_abc"
      assert msg =~ "3000"
    end

    test ":dispute_created includes dispute_id, reason, and manual review" do
      msg =
        AlertTypes.format_message(:dispute_created, %{dispute_id: "dp_1", reason: "fraudulent"})

      assert msg =~ "dp_1"
      assert msg =~ "fraudulent"
      assert msg =~ "Manual review"
    end

    test ":dispute_lost includes dispute_id and user_id" do
      msg = AlertTypes.format_message(:dispute_lost, %{dispute_id: "dp_2", user_id: 99})
      assert msg =~ "dp_2"
      assert msg =~ "99"
    end

    test ":calendar_sync_error includes email and reason" do
      msg =
        AlertTypes.format_message(:calendar_sync_error, %{
          owner_email: "a@b.com",
          reason: :timeout
        })

      assert msg =~ "a@b.com"
      assert msg =~ "timeout"
    end

    test ":pubsub_broadcast_failed includes event name" do
      msg = AlertTypes.format_message(:pubsub_broadcast_failed, %{event: :payment_successful})
      assert msg =~ "payment_successful"
    end

    test ":integration_health_failure includes integration_id" do
      msg = AlertTypes.format_message(:integration_health_failure, %{integration_id: 7})
      assert msg =~ "7"
    end

    test ":integration_health_recovery includes integration_id" do
      msg = AlertTypes.format_message(:integration_health_recovery, %{integration_id: 7})
      assert msg =~ "7"
    end

    test ":oban_queue_stuck includes queues and state" do
      msg =
        AlertTypes.format_message(:oban_queue_stuck, %{
          affected_queues: ["default"],
          job_state: "available"
        })

      assert msg =~ "default"
      assert msg =~ "available"
    end

    test ":oban_jobs_accumulating includes queues and threshold" do
      msg =
        AlertTypes.format_message(:oban_jobs_accumulating, %{
          affected_queues: ["emails"],
          threshold: 100
        })

      assert msg =~ "emails"
      assert msg =~ "100"
    end

    test ":oban_job_failure includes worker, queue, and reason" do
      msg =
        AlertTypes.format_message(:oban_job_failure, %{
          worker: "MyApp.SomeWorker",
          queue: "calendar_events",
          reason_message: "boom"
        })

      assert msg =~ "MyApp.SomeWorker"
      assert msg =~ "calendar_events"
      assert msg =~ "boom"
    end

    test ":reconciliation_discrepancies includes count" do
      msg =
        AlertTypes.format_message(:reconciliation_discrepancies, %{discrepancies_count: 3})

      assert msg =~ "3"
      assert msg =~ "discrepancies"
    end

    test ":subscription_not_in_database includes stripe subscription ID" do
      msg =
        AlertTypes.format_message(:subscription_not_in_database, %{
          stripe_subscription_id: "sub_abc123"
        })

      assert msg =~ "sub_abc123"
    end
  end

  describe "format_message/2 — fallback" do
    test "unknown type returns generic message" do
      msg = AlertTypes.format_message(:totally_unknown, %{})
      assert msg == "Alert: totally_unknown"
    end
  end

  describe "dedup_key/2" do
    test "oban_job_failure is stable across different failure reasons" do
      base = %{worker: "Tymeslot.Workers.SyncWorker", queue: "calendar_events", job_id: 1}

      key_a = AlertTypes.dedup_key(:oban_job_failure, Map.put(base, :reason_message, "boom 1"))

      key_b =
        AlertTypes.dedup_key(
          :oban_job_failure,
          base |> Map.put(:reason_message, "boom 2") |> Map.put(:job_id, 2)
        )

      assert key_a == key_b
      assert key_a =~ "Tymeslot.Workers.SyncWorker"
      assert key_a =~ "calendar_events"
    end

    test "oban_job_failure differs across workers" do
      key_a = AlertTypes.dedup_key(:oban_job_failure, %{worker: "WorkerA", queue: "q"})
      key_b = AlertTypes.dedup_key(:oban_job_failure, %{worker: "WorkerB", queue: "q"})

      refute key_a == key_b
    end

    test "other types fall back to the formatted message" do
      metadata = %{event_type: "invoice.paid", event_id: "evt_1"}

      assert AlertTypes.dedup_key(:unhandled_webhook, metadata) ==
               AlertTypes.format_message(:unhandled_webhook, metadata)
    end
  end
end
