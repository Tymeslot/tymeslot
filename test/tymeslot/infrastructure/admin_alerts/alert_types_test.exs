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
        AlertTypes.format_message(:dispute_created, %{
          dispute_id: "dp_1",
          reason_code: :dispute_created,
          reason_message: "fraudulent"
        })

      assert msg =~ "dp_1"
      assert msg =~ "fraudulent"
      assert msg =~ "Manual review"
    end

    test ":dispute_lost includes dispute_id and user_id" do
      msg = AlertTypes.format_message(:dispute_lost, %{dispute_id: "dp_2", user_id: 99})
      assert msg =~ "dp_2"
      assert msg =~ "99"
    end

    test ":calendar_sync_error includes the masked email and reason" do
      msg =
        AlertTypes.format_message(:calendar_sync_error, %{
          owner_email_masked: "a***@b.com",
          reason_code: :timeout,
          reason_message: "timeout"
        })

      assert msg =~ "a***@b.com"
      assert msg =~ "timeout"
    end

    test ":calendar_sync_error falls back to the reason code without a message" do
      message =
        AlertTypes.format_message(:calendar_sync_error, %{
          owner_email_masked: "a***@b.com",
          reason_code: :timeout
        })

      assert message == "Calendar sync error for a***@b.com: timeout"
    end

    test ":calendar_sync_error never renders a raw owner_email key" do
      message =
        AlertTypes.format_message(:calendar_sync_error, %{
          owner_email: "a@b.com",
          reason_code: :timeout
        })

      assert message == "Calendar sync error for unknown: timeout"
    end

    test ":pubsub_broadcast_failed includes event name" do
      msg = AlertTypes.format_message(:pubsub_broadcast_failed, %{event: :payment_successful})
      assert msg =~ "payment_successful"
    end

    test ":integration_health_failure includes integration_id" do
      msg = AlertTypes.format_message(:integration_health_failure, %{integration_id: 7})
      assert msg =~ "7"
    end

    test ":integration_health_failure for an aggregate signal is its summary alone" do
      msg =
        AlertTypes.format_message(:integration_health_failure, %{
          signal: "reauth_flags",
          summary: "12 calendar integration(s) newly flagged"
        })

      assert msg == "12 calendar integration(s) newly flagged"
    end

    test ":integration_health_recovery is the summary it was raised with" do
      msg =
        AlertTypes.format_message(:integration_health_recovery, %{
          signal: "reauth_flags",
          summary: "Calendar reconnection flags back under threshold"
        })

      assert msg == "Calendar reconnection flags back under threshold"
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

    test ":new_error names the exception, its source and the reason" do
      msg =
        AlertTypes.format_message(:new_error, %{
          summary: "New error",
          kind: "Elixir.RuntimeError",
          source_function: "Tymeslot.Bookings.create_booking/2",
          reason_message: "boom"
        })

      assert msg == "New error: RuntimeError in Tymeslot.Bookings.create_booking/2: boom"
    end

    test ":reconciliation_discrepancies includes count" do
      msg =
        AlertTypes.format_message(:reconciliation_discrepancies, %{discrepancies_count: 3})

      assert msg =~ "3"
      assert msg =~ "discrepancies"
    end

    test ":dunning_stalled includes the subscription ID and the days past due" do
      metadata = %{stripe_subscription_id: "sub_stalled_1", days_past_due: 312}
      msg = AlertTypes.format_message(:dunning_stalled, metadata)

      assert msg =~ "sub_stalled_1"
      assert msg =~ "312"
      assert AlertTypes.dedup_key(:dunning_stalled, metadata) =~ "sub_stalled_1"

      refute AlertTypes.dedup_key(:dunning_stalled, metadata) ==
               AlertTypes.dedup_key(:dunning_stalled, %{
                 metadata
                 | stripe_subscription_id: "sub_stalled_2"
               })
    end

    # The daily dunning run raises this type afresh each pass, with the day
    # count one higher. Keyed on the message, every pass looked new and the
    # admin was emailed daily about a condition nobody had resolved yet.
    test ":dunning_stalled dedups across runs as the day count climbs" do
      key = fn days ->
        AlertTypes.dedup_key(:dunning_stalled, %{
          stripe_subscription_id: "sub_stalled_1",
          days_past_due: days
        })
      end

      assert key.(312) == key.(313)

      refute AlertTypes.format_message(:dunning_stalled, %{
               stripe_subscription_id: "sub_stalled_1",
               days_past_due: 312
             }) ==
               AlertTypes.format_message(:dunning_stalled, %{
                 stripe_subscription_id: "sub_stalled_1",
                 days_past_due: 313
               })
    end

    test ":subscription_not_in_database includes stripe subscription ID" do
      msg =
        AlertTypes.format_message(:subscription_not_in_database, %{
          stripe_subscription_id: "sub_abc123"
        })

      assert msg =~ "sub_abc123"
    end

    test ":recipient_email_rejected includes the connect account identifier and reason" do
      msg =
        AlertTypes.format_message(:recipient_email_rejected, %{
          summary: "Recipient permanently undeliverable, email discarded",
          reason_message: "bounced",
          connect_account_id: 42
        })

      assert msg =~ "connect account 42"
      assert msg =~ "bounced"
    end

    test ":recipient_email_rejected includes the booking payment identifier when no connect account is present" do
      msg =
        AlertTypes.format_message(:recipient_email_rejected, %{
          summary: "Recipient permanently undeliverable, email discarded",
          reason_message: "bounced",
          booking_payment_id: 7
        })

      assert msg =~ "booking payment 7"
    end

    test ":recipient_email_rejected falls back to summary and reason with no identifier" do
      msg =
        AlertTypes.format_message(:recipient_email_rejected, %{
          summary: "Recipient permanently undeliverable, email discarded",
          reason_message: "bounced"
        })

      assert msg == "Recipient permanently undeliverable, email discarded: bounced"
    end

    test ":recipient_email_rejected includes the meeting identifier when no other id is present" do
      msg =
        AlertTypes.format_message(:recipient_email_rejected, %{
          summary: "Recipient permanently undeliverable, email discarded",
          reason_message: "bounced",
          meeting_id: 99
        })

      assert msg =~ "meeting 99"
    end
  end

  describe "format_message/2 — fallback" do
    test "unknown type returns generic message" do
      msg = AlertTypes.format_message(:totally_unknown, %{})
      assert msg == "Alert: totally_unknown"
    end
  end

  describe "dedup_key/2" do
    test "new_error is one key per ErrorTracker error, whatever the reason" do
      key_a = AlertTypes.dedup_key(:new_error, %{error_id: 7, reason_message: "boom 1"})
      key_b = AlertTypes.dedup_key(:new_error, %{error_id: 7, reason_message: "boom 2"})

      assert key_a == key_b
      refute key_a == AlertTypes.dedup_key(:new_error, %{error_id: 8, reason_message: "boom 1"})
    end

    test "error_regression is one key per occurrence that brought the error back" do
      key_a = AlertTypes.dedup_key(:error_regression, %{error_id: 7, occurrence_id: 40})
      key_b = AlertTypes.dedup_key(:error_regression, %{error_id: 7, occurrence_id: 41})

      refute key_a == key_b
      refute key_a == AlertTypes.dedup_key(:new_error, %{error_id: 7})
    end

    test "integration_health_failure for a signal ignores the live count" do
      base = %{signal: "reauth_flags", band: "elevated", threshold: 10}

      key_a =
        AlertTypes.dedup_key(
          :integration_health_failure,
          Map.merge(base, %{count: 11, summary: "11 flagged"})
        )

      key_b =
        AlertTypes.dedup_key(
          :integration_health_failure,
          Map.merge(base, %{count: 42, summary: "42 flagged"})
        )

      assert key_a == key_b
      assert key_a == "integration_health_failure:reauth_flags:elevated"
    end

    test "integration_health_failure for a signal differs by band, signal and run date" do
      key = &AlertTypes.dedup_key(:integration_health_failure, &1)
      elevated = key.(%{signal: "auto_pause", band: "elevated", run_date: "2026-09-22"})

      refute elevated == key.(%{signal: "auto_pause", band: "severe", run_date: "2026-09-22"})
      refute elevated == key.(%{signal: "auto_pause", band: "elevated", run_date: "2026-09-23"})
      refute elevated == key.(%{signal: "reauth_flags", band: "elevated"})
    end

    test "integration_health_failure without a signal keeps its message-based key" do
      metadata = %{summary: "Shared Telegram bot token rejected", integration_id: 3}

      assert AlertTypes.dedup_key(:integration_health_failure, metadata) ==
               AlertTypes.format_message(:integration_health_failure, metadata)
    end

    test "integration_health_recovery ignores the live count" do
      assert AlertTypes.dedup_key(:integration_health_recovery, %{
               signal: "availability_refusals",
               count: 0
             }) ==
               AlertTypes.dedup_key(:integration_health_recovery, %{
                 signal: "availability_refusals",
                 count: 3
               })
    end

    test "other types fall back to the formatted message" do
      metadata = %{event_type: "invoice.paid", event_id: "evt_1"}

      assert AlertTypes.dedup_key(:unhandled_webhook, metadata) ==
               AlertTypes.format_message(:unhandled_webhook, metadata)
    end

    # analytics_tracking_anomaly dedup_key/2 — spam-prevention invariant:
    # two payloads with the same :kind but different per-run counts must produce
    # an identical key so that a recurring daily anomaly collapses to one alert
    # per dedup window.
    test "analytics_tracking_anomaly is stable across different per-run counts" do
      key_a =
        AlertTypes.dedup_key(:analytics_tracking_anomaly, %{
          kind: :converting_exceeds_unique,
          converting_visitors: 10,
          unique_visitors: 8
        })

      key_b =
        AlertTypes.dedup_key(:analytics_tracking_anomaly, %{
          kind: :converting_exceeds_unique,
          converting_visitors: 999,
          unique_visitors: 1
        })

      assert key_a == key_b
      assert key_a =~ "analytics_tracking_anomaly"
      assert key_a =~ "converting_exceeds_unique"
    end

    test "analytics_tracking_anomaly differs across anomaly kinds" do
      key_a =
        AlertTypes.dedup_key(:analytics_tracking_anomaly, %{
          kind: :converting_exceeds_unique,
          converting_visitors: 5,
          unique_visitors: 3
        })

      key_b =
        AlertTypes.dedup_key(:analytics_tracking_anomaly, %{
          kind: :high_untracked_ratio,
          converting_visitors: 5,
          unique_visitors: 3
        })

      refute key_a == key_b
    end

    test "analytics_tracking_anomaly falls back to 'unknown' when :kind is absent" do
      key = AlertTypes.dedup_key(:analytics_tracking_anomaly, %{converting_visitors: 5})
      assert key == "analytics_tracking_anomaly:unknown"
    end

    # The headline names the owner by masked address, which two owners can
    # share, so the key identifies the failing calendar, and never the owner.
    test "calendar_sync_error keys on the integration, then the meeting, never the owner" do
      base = %{owner_email: "owner@example.com", reason_message: "boom"}
      with_meeting = Map.put(base, :meeting_id, 10)
      with_integration = Map.put(with_meeting, :calendar_integration_id, 1)

      assert AlertTypes.dedup_key(:calendar_sync_error, with_integration) ==
               "calendar_sync_error:integration 1:boom"

      assert AlertTypes.dedup_key(:calendar_sync_error, with_meeting) ==
               "calendar_sync_error:meeting 10:boom"

      assert AlertTypes.dedup_key(:calendar_sync_error, base) ==
               "calendar_sync_error:unknown:boom"
    end

    # A rejected recipient's identity is the account it belongs to, not the
    # rejection reason: two different hosts' bounces inside the same dedup
    # window must raise two alerts, not collapse into one.
    test "recipient_email_rejected differs across connect accounts" do
      key_a =
        AlertTypes.dedup_key(:recipient_email_rejected, %{
          reason_message: "bounced",
          connect_account_id: 1
        })

      key_b =
        AlertTypes.dedup_key(:recipient_email_rejected, %{
          reason_message: "bounced",
          connect_account_id: 2
        })

      refute key_a == key_b
    end

    test "recipient_email_rejected is stable across differing reasons for the same connect account" do
      key_a =
        AlertTypes.dedup_key(:recipient_email_rejected, %{
          reason_message: "bounced",
          connect_account_id: 1
        })

      key_b =
        AlertTypes.dedup_key(:recipient_email_rejected, %{
          reason_message: "mailbox full",
          connect_account_id: 1
        })

      assert key_a == key_b
      assert key_a =~ "recipient_email_rejected"
      assert key_a =~ "1"
    end

    test "recipient_email_rejected differs across booking payments" do
      key_a =
        AlertTypes.dedup_key(:recipient_email_rejected, %{
          reason_message: "bounced",
          booking_payment_id: 10
        })

      key_b =
        AlertTypes.dedup_key(:recipient_email_rejected, %{
          reason_message: "bounced",
          booking_payment_id: 20
        })

      refute key_a == key_b
    end

    test "recipient_email_rejected without an identifier falls back to the formatted message" do
      metadata = %{summary: "Recipient permanently undeliverable", reason_message: "bounced"}

      assert AlertTypes.dedup_key(:recipient_email_rejected, metadata) ==
               AlertTypes.format_message(:recipient_email_rejected, metadata)
    end

    # EmailWorker — the caller responsible for the overwhelming majority of
    # recipient rejections — has no connect account or booking payment to
    # hand, only the meeting the email was for. Without this, every rejection
    # from that path fell back to the message-based key and collapsed
    # unrelated meetings into one alert per day.
    test "recipient_email_rejected differs across meetings" do
      key_a =
        AlertTypes.dedup_key(:recipient_email_rejected, %{
          reason_message: "bounced",
          meeting_id: 1
        })

      key_b =
        AlertTypes.dedup_key(:recipient_email_rejected, %{
          reason_message: "bounced",
          meeting_id: 2
        })

      refute key_a == key_b
    end
  end
end
