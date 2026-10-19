defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedLateTest do
  @moduledoc """
  `checkout.session.completed` arriving after its booking expired and its
  payment was failed (the expired webhook, or a disconnect, ran first). The
  money was taken all the same, so the booking is brought back when its slot
  is still free and the payment is refunded, by `RefundLatePayment`, when it
  is not.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  @account "acct_TEST_HOST"
  @paid_session %{"payment_status" => "paid", "amount_total" => 5000, "currency" => "eur"}

  import Ecto.Query, only: [from: 2]
  import Mox, only: [expect: 3, stub: 3, verify_on_exit!: 1]
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  setup :verify_on_exit!

  describe "handle/1 after the booking expired" do
    test "recovers when expired webhook beat the completed webhook (race E3)" do
      # Regression for E3: checkout.session.expired arrived first, transitioning
      # the meeting to expired and booking_payment to failed. The subsequent
      # completed event must recover, its slot being still free: re-confirm the
      # meeting and mark payment paid.
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: "expired",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      bp =
        insert_payment(
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_RACE_E3"
        )

      event =
        completed_event("evt_RACE_E3", %{
          "id" => "cs_RACE_E3",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_RACE_E3"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)

      reloaded_bp = Repo.reload!(bp)
      assert reloaded_bp.status == "paid"
      assert reloaded_bp.paid_at
      assert reloaded_bp.stripe_payment_intent_id == "pi_RACE_E3"
      assert reloaded_bp.last_event_id == "evt_RACE_E3"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "confirmed"
    end

    test "recovers a meeting whose other fields no longer pass validation" do
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: "expired",
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id), set: [attendee_name: nil])

      bp =
        insert_payment(
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_LATE_LEGACY"
        )

      assert :ok = CheckoutSessionCompleted.handle(late_event("LATE_LEGACY", meeting))

      assert Repo.reload!(bp).status == "paid"
      assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
    end

    # The expiry released the slot, and another booking has taken it since:
    # the attendee's money goes back instead of a double booking. The webhook
    # records the payment and schedules the refund; the job makes it.
    test "refunds a completion that arrived after expiry once the slot has been taken" do
      user = insert(:user)
      {meeting, bp} = taken_slot_booking(user, "LATE_TAKEN")

      stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_LATE_TAKEN", opts ->
        assert opts[:connect_account] == @account
        {:ok, %{"latest_charge" => "ch_LATE_TAKEN"}}
      end)

      assert :ok = CheckoutSessionCompleted.handle(late_event("LATE_TAKEN", meeting))

      recorded = Repo.reload!(bp)
      assert recorded.status == "paid"
      assert recorded.paid_at
      assert recorded.stripe_charge_id == "ch_LATE_TAKEN"
      assert recorded.last_event_id == "evt_LATE_TAKEN"
      assert_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: bp.id})
      refute_enqueued(worker: SendBookingPaymentRefunded)

      expect(StripeAdapterMock, :create_refund, fn params, opts ->
        assert params.charge == "ch_LATE_TAKEN"
        assert params.amount == bp.amount_cents
        assert opts[:connect_account] == @account
        {:ok, %{"id" => "re_LATE_TAKEN"}}
      end)

      assert %{success: 1} = Oban.drain_queue(queue: :payments)

      reloaded_bp = Repo.reload!(bp)
      assert reloaded_bp.status == "refunded"
      assert reloaded_bp.refunded_amount_cents == bp.amount_cents

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "expired"

      assert [_one] =
               all_enqueued(
                 worker: SendBookingPaymentRefunded,
                 args: %{booking_payment_id: bp.id}
               )

      refute_enqueued(worker: CalendarEventWorker)
      refute_enqueued(worker: EmailWorker)
    end

    # Stripe's redelivery, and the reconciler's replay under its own event id,
    # find the payment already recorded and must not schedule a second refund.
    test "a redelivered late completion schedules no second refund" do
      user = insert(:user)
      {meeting, bp} = taken_slot_booking(user, "LATE_AGAIN")

      stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
        {:ok, %{"latest_charge" => "ch_LATE_AGAIN"}}
      end)

      event = late_event("LATE_AGAIN", meeting)

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert :ok = CheckoutSessionCompleted.handle(event)
      assert :ok = CheckoutSessionCompleted.handle(%{event | "id" => "reconcile:cs_LATE_AGAIN"})

      assert [_one] = all_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: bp.id})
    end

    test "refunds a completion that arrived after expiry for a meeting whose organiser is gone" do
      meeting = insert(:meeting, status: "expired", organizer_user_id: nil)

      bp =
        insert_payment(
          meeting: meeting,
          status: "failed",
          stripe_checkout_session_id: "cs_LATE_ORPHAN"
        )

      stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
        {:ok, %{"latest_charge" => "ch_LATE_ORPHAN"}}
      end)

      expect(StripeAdapterMock, :create_refund, fn %{charge: "ch_LATE_ORPHAN"}, _opts ->
        {:ok, %{"id" => "re_LATE_ORPHAN"}}
      end)

      event =
        completed_event("evt_LATE_ORPHAN", %{
          "id" => "cs_LATE_ORPHAN",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_LATE_ORPHAN"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert %{success: 1} = Oban.drain_queue(queue: :payments)

      assert Repo.reload!(bp).status == "refunded"
      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "expired"
    end

    # The refund needs the charge id, which only Stripe can supply. Held back
    # until Stripe supplied it, the payment stayed `failed`, off the host's
    # outstanding refunds, once Stripe stopped redelivering. It is committed
    # paid with its job instead, and the job backfills the charge id first.
    test "records a late completion and its refund even when its charge cannot be found yet" do
      user = insert(:user)
      {meeting, bp} = taken_slot_booking(user, "LATE_NO_CHARGE")
      stripe_up = start_supervised!({Agent, fn -> false end})

      stub(StripeAdapterMock, :retrieve_payment_intent, fn "pi_LATE_NO_CHARGE", opts ->
        assert opts[:connect_account] == @account

        if Agent.get(stripe_up, & &1),
          do: {:ok, %{"latest_charge" => "ch_LATE_NO_CHARGE"}},
          else: {:error, :stripe_down}
      end)

      event = late_event("LATE_NO_CHARGE", meeting)
      assert :ok = CheckoutSessionCompleted.handle(event)

      recorded = Repo.reload!(bp)
      assert recorded.status == "paid"
      assert is_nil(recorded.stripe_charge_id)
      assert recorded.last_event_id == "evt_LATE_NO_CHARGE"
      assert [job] = all_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: bp.id})
      bp_id = bp.id
      assert [%{id: ^bp_id}] = MeetingPayments.list_outstanding_refunds_for_host(bp.host_user_id)

      # Stripe's redelivery and the reconciler's replay change nothing.
      assert :ok = CheckoutSessionCompleted.handle(event)

      assert :ok =
               CheckoutSessionCompleted.handle(%{event | "id" => "reconcile:cs_LATE_NO_CHARGE"})

      assert [^job] = all_enqueued(worker: RefundLatePayment, args: %{booking_payment_id: bp.id})
      assert Repo.reload!(bp).last_event_id == "evt_LATE_NO_CHARGE"

      # The job retries while the charge id is still unavailable.
      assert {:error, :stripe_down} =
               perform_job(RefundLatePayment, %{booking_payment_id: bp.id}, attempt: 1)

      assert Repo.reload!(bp).status == "paid"

      Agent.update(stripe_up, fn _down -> true end)

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.charge == "ch_LATE_NO_CHARGE"
        assert params.amount == bp.amount_cents
        {:ok, %{"id" => "re_LATE_NO_CHARGE"}}
      end)

      assert :ok = perform_job(RefundLatePayment, %{booking_payment_id: bp.id}, attempt: 2)

      refunded = Repo.reload!(bp)
      assert refunded.status == "refunded"
      assert refunded.stripe_charge_id == "ch_LATE_NO_CHARGE"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == "expired"
    end
  end

  # An expired booking whose slot another confirmed booking now holds.
  # The attendee disputes the late payment before the refund job runs, so
  # the job leaves it to the dispute. When the host wins, the money is back
  # with them for a booking that never happened, and is refunded after all.
  describe "a late payment disputed before its refund" do
    test "is refunded, once, after the host wins the dispute" do
      user = insert(:user)
      {meeting, bp} = taken_slot_booking(user, "LATE_DISPUTED")

      stub(StripeAdapterMock, :retrieve_payment_intent, fn _id, _opts ->
        {:ok, %{"latest_charge" => "ch_LATE_DISPUTED"}}
      end)

      assert :ok = CheckoutSessionCompleted.handle(late_event("LATE_DISPUTED", meeting))

      assert :ok =
               ChargeDisputeCreated.handle(
                 dispute_event("evt_DISPUTE_OPENED", "charge.dispute.created", %{
                   "reason" => "fraudulent"
                 })
               )

      assert %{discard: 1} = Oban.drain_queue(queue: :payments)
      assert Repo.reload!(bp).status == "disputed"

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.charge == "ch_LATE_DISPUTED"
        assert params.amount == bp.amount_cents
        {:ok, %{"id" => "re_LATE_DISPUTED"}}
      end)

      assert %{success: 1} = Oban.drain_queue(queue: :payments)

      assert Repo.reload!(bp).status == "refunded"
      assert {:ok, %{status: "expired"}} = MeetingQueries.get_meeting(meeting.id)

      assert [_one] =
               all_enqueued(
                 worker: SendBookingPaymentRefunded,
                 args: %{booking_payment_id: bp.id}
               )

      # A redelivered outcome schedules nothing more.
      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON_2", "charge.dispute.closed", %{"status" => "won"})
               )

      refund_jobs =
        Repo.all(
          from(j in Oban.Job,
            where: j.worker == "Tymeslot.MeetingPayments.Workers.RefundLatePayment",
            select: {j.state, j.args}
          )
        )

      assert Enum.sort(refund_jobs) == [
               {"completed", %{"booking_payment_id" => bp.id, "reason" => "after_dispute"}},
               {"discarded", %{"booking_payment_id" => bp.id}}
             ]
    end

    # Whatever the dispute decided, what is left with the host for a booking
    # that never happened goes back to the attendee.
    test "refunds what is left after a won dispute on a partly refunded payment" do
      bp = disputed_expired_payment(refunded_amount_cents: 1500)

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      assert Repo.reload!(bp).status == "partially_refunded"
      assert_remainder_refunded(bp, 3500)
    end

    test "refunds what is left after a partly lost dispute" do
      bp = disputed_expired_payment(refunded_amount_cents: 0)

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_LOST", "charge.dispute.closed", %{
                   "status" => "lost",
                   "amount" => 2000
                 })
               )

      assert %{status: "partially_refunded", refunded_amount_cents: 2000} = Repo.reload!(bp)
      assert_remainder_refunded(bp, 3000)
    end

    test "schedules no refund for a dispute the host wins on a booking that went ahead" do
      meeting = insert(:meeting, status: "confirmed")

      insert_payment(
        meeting: meeting,
        status: "disputed",
        paid_at: DateTime.utc_now(:second),
        stripe_charge_id: "ch_LATE_DISPUTED"
      )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      refute_enqueued(worker: RefundLatePayment)
    end
  end

  defp disputed_expired_payment(attrs) do
    meeting = insert(:meeting, status: "expired")

    insert_payment(
      [
        meeting: meeting,
        status: "disputed",
        amount_cents: 5000,
        paid_at: DateTime.utc_now(:second),
        stripe_charge_id: "ch_LATE_DISPUTED"
      ] ++ attrs
    )
  end

  defp assert_remainder_refunded(bp, remainder) do
    expect(StripeAdapterMock, :create_refund, fn params, _opts ->
      assert params.charge == "ch_LATE_DISPUTED"
      assert params.amount == remainder
      {:ok, %{"id" => "re_#{bp.id}"}}
    end)

    assert %{success: 1} = Oban.drain_queue(queue: :payments)
    assert %{status: "refunded", refunded_amount_cents: 5000} = Repo.reload!(bp)
  end

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
              "id" => "dp_LATE_DISPUTED",
              "object" => "dispute",
              "charge" => "ch_LATE_DISPUTED",
              "amount" => 5000
            },
            fields
          )
      }
    }
  end

  defp taken_slot_booking(user, suffix) do
    meeting =
      insert(:meeting,
        status: "expired",
        organizer_user_id: user.id,
        organizer_email: user.email
      )

    _taker =
      insert(:meeting,
        status: "confirmed",
        organizer_user_id: user.id,
        start_time: meeting.start_time,
        end_time: meeting.end_time
      )

    payment =
      insert_payment(
        meeting: meeting,
        status: "failed",
        stripe_checkout_session_id: "cs_#{suffix}"
      )

    {meeting, payment}
  end

  defp late_event(suffix, meeting) do
    completed_event("evt_#{suffix}", %{
      "id" => "cs_#{suffix}",
      "client_reference_id" => meeting.id,
      "payment_intent" => "pi_#{suffix}"
    })
  end

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
