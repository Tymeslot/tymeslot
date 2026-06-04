defmodule Tymeslot.MeetingPayments.TelemetryTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  import Mox

  alias Tymeslot.MeetingPayments.StripeAdapter
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Telemetry, as: PaymentsTelemetry
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired

  setup :verify_on_exit!
  setup :set_mox_from_context

  describe "emit_status_changed/3" do
    test "emits a telemetry event when from and to differ" do
      handler_id = "test-status-changed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        PaymentsTelemetry.status_changed_event(),
        fn _name, measurements, metadata, _config ->
          send(self(), {:status_changed, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = PaymentsTelemetry.emit_status_changed("pending", "paid", :webhook_paid)

      assert_received {:status_changed, %{count: 1},
                       %{from: :pending, to: :paid, reason: :webhook_paid}}
    end

    test "does not emit when status is unchanged" do
      handler_id = "test-status-unchanged-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        PaymentsTelemetry.status_changed_event(),
        fn _name, _measurements, _metadata, _config ->
          send(self(), :unexpected_event)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert :ok = PaymentsTelemetry.emit_status_changed("paid", "paid", :webhook_paid)

      refute_received :unexpected_event
    end
  end

  describe "Stripe API span" do
    test "emits :stop with status :ok on a successful adapter call" do
      handler_id = "test-stripe-ok-#{System.unique_integer([:positive])}"
      :telemetry_test.attach_event_handlers(self(), [PaymentsTelemetry.stripe_event() ++ [:stop]])

      on_exit(fn -> :telemetry.detach(handler_id) end)

      expect(StripeAdapterMock, :retrieve_account, fn "acct_TEL" ->
        {:ok, %{"id" => "acct_TEL"}}
      end)

      assert {:ok, _account} = StripeAdapter.retrieve_account("acct_TEL")

      assert_received {[_, _, :stripe, :api, :stop], _ref, _measurements,
                       %{operation: :retrieve_account, account_id: "acct_TEL", status: :ok}}
    end

    test "emits :stop with status :error when the adapter returns an error" do
      :telemetry_test.attach_event_handlers(self(), [PaymentsTelemetry.stripe_event() ++ [:stop]])

      expect(StripeAdapterMock, :retrieve_account, fn _id -> {:error, %{message: "boom"}} end)

      assert {:error, _reason} = StripeAdapter.retrieve_account("acct_FAIL")

      assert_received {[_, _, :stripe, :api, :stop], _ref, _measurements,
                       %{operation: :retrieve_account, status: :error}}
    end
  end

  describe "Webhook span" do
    test "emits :ok processed metadata on a fresh CheckoutSessionCompleted event" do
      meeting = insert(:meeting, status: "awaiting_payment")

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_TEL_OK"
        )

      :telemetry_test.attach_event_handlers(self(), [PaymentsTelemetry.webhook_event() ++ [:stop]])

      event = %{
        "id" => "evt_TEL_OK",
        "data" => %{
          "object" => %{
            "id" => "cs_TEL_OK",
            "client_reference_id" => meeting.id,
            "payment_intent" => "pi_TEL_OK"
          }
        }
      }

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert_received {[_, _, :webhook, :received, :stop], _ref, _measurements,
                       %{event_type: "checkout.session.completed", processed: :ok}}
    end

    test "a successful paid booking emits anonymous booking_payment_succeeded telemetry" do
      meeting = insert(:meeting, status: "awaiting_payment")

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          currency: "eur",
          stripe_checkout_session_id: "cs_TEL_ANALYTICS"
        )

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:tymeslot, :meeting_payments, :booking_payment, :succeeded]
        ])

      event = %{
        "id" => "evt_TEL_ANALYTICS",
        "data" => %{
          "object" => %{
            "id" => "cs_TEL_ANALYTICS",
            "client_reference_id" => meeting.id,
            "payment_intent" => "pi_TEL_ANALYTICS"
          }
        }
      }

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert_received {[:tymeslot, :meeting_payments, :booking_payment, :succeeded], ^ref,
                       %{count: 1}, metadata}

      assert metadata == %{currency: "eur", has_video: false}
      refute Map.has_key?(metadata, :user_id)
      refute Map.has_key?(metadata, :amount)
    end

    test "a recovered paid booking also emits booking_payment_succeeded telemetry" do
      # Simulates the race where checkout.session.completed arrives after the
      # expiry webhook has already run — the meeting is expired and the payment
      # is in a failed/cancelled state.
      meeting = insert(:meeting, status: "expired")

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "failed",
          currency: "usd",
          stripe_checkout_session_id: "cs_TEL_RECOVERED"
        )

      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:tymeslot, :meeting_payments, :booking_payment, :succeeded]
        ])

      event = %{
        "id" => "evt_TEL_RECOVERED",
        "data" => %{
          "object" => %{
            "id" => "cs_TEL_RECOVERED",
            "client_reference_id" => meeting.id,
            "payment_intent" => "pi_TEL_RECOVERED"
          }
        }
      }

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert_received {[:tymeslot, :meeting_payments, :booking_payment, :succeeded], ^ref,
                       %{count: 1}, metadata}

      assert metadata == %{currency: "usd", has_video: false}
      refute Map.has_key?(metadata, :user_id)
      refute Map.has_key?(metadata, :amount)
    end

    test "emits :idempotent_replay processed metadata on a replay" do
      meeting = insert(:meeting, status: "awaiting_payment")

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "paid",
          paid_at: DateTime.utc_now(:second),
          stripe_checkout_session_id: "cs_TEL_REPLAY",
          last_event_id: "evt_TEL_REPLAY"
        )

      :telemetry_test.attach_event_handlers(self(), [PaymentsTelemetry.webhook_event() ++ [:stop]])

      event = %{
        "id" => "evt_TEL_REPLAY",
        "data" => %{
          "object" => %{
            "id" => "cs_TEL_REPLAY",
            "client_reference_id" => meeting.id
          }
        }
      }

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert_received {[_, _, :webhook, :received, :stop], _ref, _measurements,
                       %{event_type: "checkout.session.completed", processed: :idempotent_replay}}
    end

    test "emits :error processed metadata on an invalid event" do
      :telemetry_test.attach_event_handlers(self(), [PaymentsTelemetry.webhook_event() ++ [:stop]])

      assert {:error, :invalid_event} = CheckoutSessionExpired.handle(%{"bogus" => true})

      assert_received {[_, _, :webhook, :received, :stop], _ref, _measurements,
                       %{event_type: "checkout.session.expired", processed: :error}}
    end
  end

  describe "status_changed wired into CheckoutSessionCompleted" do
    test "emits a status_changed event when the booking transitions pending → paid" do
      meeting = insert(:meeting, status: "awaiting_payment")

      _bp =
        insert(:booking_payment,
          meeting: meeting,
          status: "pending",
          stripe_checkout_session_id: "cs_STATUS"
        )

      :telemetry_test.attach_event_handlers(self(), [PaymentsTelemetry.status_changed_event()])

      event = %{
        "id" => "evt_STATUS",
        "data" => %{
          "object" => %{
            "id" => "cs_STATUS",
            "client_reference_id" => meeting.id,
            "payment_intent" => "pi_STATUS"
          }
        }
      }

      assert :ok = CheckoutSessionCompleted.handle(event)

      assert_received {[_, _, :booking_payment, :status_changed], _ref, %{count: 1},
                       %{from: :pending, to: :paid, reason: :webhook_paid}}
    end
  end
end
