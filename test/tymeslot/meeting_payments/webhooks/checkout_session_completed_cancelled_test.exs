defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedCancelledTest do
  @moduledoc """
  `checkout.session.completed` for a booking released before its payment
  was recorded: the host cancelled it while its checkout was open, and the
  attendee paid before the checkout could be closed. The money was taken for
  a booking that will not happen, so the payment is recorded and all of it
  refunded, and the booking stays cancelled, after a won dispute too.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  @account "acct_TEST_HOST"
  @paid_session %{"payment_status" => "paid", "amount_total" => 5000, "currency" => "eur"}

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Checkout

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  describe "handle/1 for a booking cancelled while its checkout was open" do
    test "records the payment, keeps the booking cancelled and refunds all of it" do
      meeting = cancelled_meeting()

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_CANCELLED_PAID"
        )

      Phoenix.PubSub.subscribe(Tymeslot.PubSub, Checkout.payment_topic(meeting.id))

      assert :ok =
               CheckoutSessionCompleted.handle(
                 cancelled_paid_event("evt_CANCELLED_PAID", meeting)
               )

      recorded = Repo.reload!(bp)
      assert recorded.status == :paid
      assert recorded.paid_at
      assert recorded.last_event_id == "evt_CANCELLED_PAID"

      assert [%{source: :late_payment, amount_cents: 5000, status: :pending}] = refunds(bp)
      assert [_job] = all_enqueued(worker: ExecuteRefund)

      {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded.status == :cancelled

      assert_receive :expired, 1_000
      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: EmailWorker)

      # Until the refund goes through, the host sees it owed.
      assert [%{id: id}] = BookingPayments.list_outstanding_refunds_for_host(bp.host_user_id)
      assert id == bp.id
    end

    test "a redelivery, or the reconciler's replay, refunds it once" do
      meeting = cancelled_meeting()

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_CANCELLED_PAID"
        )

      event = cancelled_paid_event("evt_CANCELLED_AGAIN", meeting)

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert :ok = CheckoutSessionCompleted.handle(event)

      assert :ok =
               CheckoutSessionCompleted.handle(%{event | "id" => "reconcile:cs_CANCELLED_PAID"})

      assert [_one] = refunds(bp)
      assert [_job] = all_enqueued(worker: ExecuteRefund)
      assert Repo.reload!(bp).last_event_id == "evt_CANCELLED_AGAIN"
    end

    # A payment failed already (its checkout closed by a disconnect, say)
    # whose charge went through all the same: the cancelled booking is not
    # brought back the way an expired one can be.
    test "refunds a failed payment of a cancelled booking rather than reinstating it" do
      meeting = cancelled_meeting()

      bp =
        insert_payment(
          meeting: meeting,
          status: :failed,
          stripe_checkout_session_id: "cs_CANCELLED_PAID"
        )

      assert :ok =
               CheckoutSessionCompleted.handle(
                 cancelled_paid_event("evt_CANCELLED_FAILED", meeting)
               )

      assert %{status: :paid} = Repo.reload!(bp)
      assert [%{source: :late_payment, amount_cents: 5000}] = refunds(bp)
      assert {:ok, %{status: :cancelled}} = MeetingQueries.get_meeting(meeting.id)
    end
  end

  # The refund recorded with the payment cannot be made while a dispute
  # holds the money. Once the host wins it, what is left goes back to the
  # attendee, as for an expired booking; a booking that went ahead and was
  # cancelled later keeps whatever refund its host chose.
  describe "a dispute won on a cancelled booking" do
    test "refunds what is left of a payment completed after the cancellation" do
      meeting = cancelled_meeting()

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_CANCELLED_PAID"
        )

      StripeStub.stub(
        :retrieve_payment_intent,
        StripeStubResponses.payment_intent("pi_CANCELLED_PAID", "ch_CANCELLED_PAID")
      )

      assert :ok =
               CheckoutSessionCompleted.handle(
                 cancelled_paid_event("evt_CANCELLED_DISPUTED", meeting)
               )

      assert :ok =
               ChargeDisputeCreated.handle(
                 dispute_event("evt_DISPUTE_OPENED", "charge.dispute.created", %{
                   "reason" => "fraudulent"
                 })
               )

      # The refund's attempt finds the payment disputed and gives it up.
      StripeStub.expect(:create_refund, {:error_fixture, "invalid_request_error"})
      assert %{cancelled: 1} = drain_payments()
      assert Repo.reload!(bp).status == :disputed

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_CANCELLED_DISPUTED"))
      assert %{success: 1} = drain_payments()

      assert [_refused, %{form: form}] = StripeStub.requests(:create_refund)
      assert form["charge"] == "ch_CANCELLED_PAID"
      assert form["amount"] == "5000"

      assert %{status: :refunded, refunded_amount_cents: 5000} = Repo.reload!(bp)
      assert {:ok, %{status: :cancelled}} = MeetingQueries.get_meeting(meeting.id)

      assert [_one] =
               all_enqueued(
                 worker: SendBookingPaymentRefunded,
                 args: %{booking_payment_id: bp.id}
               )

      assert bp |> refunds() |> Enum.map(&{&1.source, &1.status}) |> Enum.sort() ==
               [{:late_payment, :failed}, {:late_payment, :succeeded}]
    end

    # The dispute lands before the completion: the completion refuses the
    # booking while Stripe holds the money, so its refund is recorded failed
    # rather than made, and the won dispute's close still finds it owed.
    test "refunds a payment whose dispute opened before its completion was recorded" do
      meeting = cancelled_meeting()

      bp =
        insert_payment(
          meeting: meeting,
          status: :pending,
          stripe_checkout_session_id: "cs_CANCELLED_PAID",
          stripe_payment_intent_id: "pi_CANCELLED_PAID"
        )

      assert :ok =
               ChargeDisputeCreated.handle(
                 dispute_event("evt_DISPUTE_FIRST", "charge.dispute.created", %{
                   "reason" => "fraudulent",
                   "payment_intent" => "pi_CANCELLED_PAID"
                 })
               )

      assert %{status: :disputed, paid_at: nil} = Repo.reload!(bp)

      StripeStub.stub(
        :retrieve_payment_intent,
        StripeStubResponses.payment_intent("pi_CANCELLED_PAID", "ch_CANCELLED_PAID")
      )

      assert :ok =
               CheckoutSessionCompleted.handle(
                 cancelled_paid_event("evt_COMPLETED_DISPUTED", meeting)
               )

      assert %{status: :disputed, paid_at: %DateTime{}} = Repo.reload!(bp)

      assert [%{source: :late_payment, status: :failed, failure_code: "under_dispute"}] =
               refunds(bp)

      refute_enqueued(worker: ExecuteRefund)

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_FIRST_WON", "charge.dispute.closed", %{
                   "status" => "won"
                 })
               )

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_DISPUTE_FIRST"))
      assert %{success: 1} = drain_payments()

      assert [%{form: %{"charge" => "ch_CANCELLED_PAID", "amount" => "5000"}}] =
               StripeStub.requests(:create_refund)

      assert %{status: :refunded, refunded_amount_cents: 5000} = Repo.reload!(bp)
      assert {:ok, %{status: :cancelled}} = MeetingQueries.get_meeting(meeting.id)

      assert bp |> refunds() |> Enum.map(&{&1.source, &1.status}) |> Enum.sort() ==
               [{:late_payment, :failed}, {:late_payment, :succeeded}]
    end

    test "refunds nothing the host did not choose for a booking paid before it was cancelled" do
      now = DateTime.utc_now(:second)

      meeting =
        insert(:meeting, status: :cancelled, cancelled_at: DateTime.add(now, -1, :day))

      bp =
        insert_payment(
          meeting: meeting,
          status: :disputed,
          paid_at: DateTime.add(now, -2, :day),
          stripe_charge_id: "ch_CANCELLED_PAID"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      assert Repo.reload!(bp).status == :paid
      assert refunds(bp) == []
      refute_enqueued(worker: ExecuteRefund)
    end

    test "refunds a payment refused in the second the booking was cancelled" do
      now = DateTime.utc_now(:second)
      meeting = insert(:meeting, status: :cancelled, cancelled_at: now)

      bp =
        insert_payment(
          meeting: meeting,
          status: :disputed,
          paid_at: now,
          stripe_charge_id: "ch_CANCELLED_PAID"
        )

      insert(:booking_payment_refund,
        booking_payment: bp,
        amount_cents: 5000,
        source: :late_payment,
        status: :failed,
        failure_code: "under_dispute"
      )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      assert bp |> refunds() |> Enum.map(&{&1.source, &1.status}) |> Enum.sort() ==
               [{:late_payment, :failed}, {:late_payment, :pending}]
    end

    test "refunds nothing for a booking paid for in the second before it was cancelled" do
      now = DateTime.utc_now(:second)
      meeting = insert(:meeting, status: :cancelled, cancelled_at: now)

      bp =
        insert_payment(
          meeting: meeting,
          status: :disputed,
          paid_at: now,
          stripe_charge_id: "ch_CANCELLED_PAID"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      assert Repo.reload!(bp).status == :paid
      assert refunds(bp) == []
    end
  end

  # Cancelled a minute before its checkout completes.
  defp cancelled_meeting do
    insert(:meeting,
      status: :cancelled,
      cancelled_at: DateTime.add(DateTime.utc_now(:second), -60, :second)
    )
  end

  defp drain_payments, do: Oban.drain_queue(queue: :payments, with_scheduled: true)

  defp dispute_event(event_id, type, fields) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => type,
      "created" => System.os_time(:second),
      "data" => %{
        "object" =>
          Map.merge(
            %{
              "id" => "dp_CANCELLED_PAID",
              "object" => "dispute",
              "charge" => "ch_CANCELLED_PAID",
              "amount" => 5000
            },
            fields
          )
      }
    }
  end

  defp cancelled_paid_event(event_id, meeting) do
    completed_event(event_id, %{
      "id" => "cs_CANCELLED_PAID",
      "client_reference_id" => meeting.id,
      "payment_intent" => "pi_CANCELLED_PAID"
    })
  end

  defp refunds(bp), do: Repo.all(from(r in RefundSchema, where: r.booking_payment_id == ^bp.id))

  defp insert_payment(attrs),
    do: insert(:booking_payment, Keyword.put_new(attrs, :stripe_account_id, @account))

  defp completed_event(event_id, object) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{"object" => Map.merge(@paid_session, object)}
    }
  end
end
