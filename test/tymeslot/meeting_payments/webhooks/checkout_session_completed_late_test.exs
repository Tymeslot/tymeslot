defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedLateTest do
  @moduledoc """
  `checkout.session.completed` arriving after its booking expired and its
  payment was failed (the expired webhook, or a disconnect, ran first). The
  money was taken all the same, so the booking is brought back when its slot
  is still free and a refund of all of it recorded, made by its
  `ExecuteRefund` job, when it is not.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  @account "acct_TEST_HOST"
  @paid_session %{"payment_status" => "paid", "amount_total" => 5000, "currency" => "eur"}

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.Invitations

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeCreated
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  describe "handle/1 after the booking expired" do
    test "recovers when expired webhook beat the completed webhook (race E3)" do
      # Regression for E3: checkout.session.expired arrived first, transitioning
      # the meeting to expired and booking_payment to failed. The subsequent
      # completed event must recover, its slot being still free: re-confirm the
      # meeting and mark payment paid.
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: :expired,
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      bp =
        insert_payment(
          meeting: meeting,
          status: :failed,
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
      assert reloaded_bp.status == :paid
      assert reloaded_bp.paid_at
      assert reloaded_bp.stripe_payment_intent_id == "pi_RACE_E3"
      assert reloaded_bp.last_event_id == "evt_RACE_E3"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == :confirmed
    end

    test "recovers a meeting whose other fields no longer pass validation" do
      user = insert(:user)

      meeting =
        insert(:meeting,
          status: :expired,
          organizer_user_id: user.id,
          organizer_email: user.email
        )

      Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id), set: [attendee_name: nil])

      bp =
        insert_payment(
          meeting: meeting,
          status: :failed,
          stripe_checkout_session_id: "cs_LATE_LEGACY"
        )

      assert :ok = CheckoutSessionCompleted.handle(late_event("LATE_LEGACY", meeting))

      assert Repo.reload!(bp).status == :paid
      assert {:ok, %{status: :confirmed}} = MeetingQueries.get_meeting(meeting.id)
    end

    # The expiry released the slot, and another booking has taken it since:
    # the attendee's money goes back instead of a double booking. The webhook
    # records the payment and its refund; the refund's job makes it.
    test "refunds a completion that arrived after expiry once the slot has been taken" do
      user = insert(:user)
      {meeting, bp} = taken_slot_booking(user, "LATE_TAKEN")

      StripeStub.stub(:retrieve_payment_intent, payment_intent("pi_LATE_TAKEN", "ch_LATE_TAKEN"))

      assert :ok = CheckoutSessionCompleted.handle(late_event("LATE_TAKEN", meeting))

      assert [%{path: "/v1/payment_intents/pi_LATE_TAKEN", headers: lookup_headers}] =
               StripeStub.requests(:retrieve_payment_intent)

      assert lookup_headers["stripe-account"] == @account

      recorded = Repo.reload!(bp)
      assert recorded.status == :paid
      assert recorded.paid_at
      assert recorded.stripe_charge_id == "ch_LATE_TAKEN"
      assert recorded.last_event_id == "evt_LATE_TAKEN"
      assert [%{source: :late_payment, amount_cents: 5000}] = refunds(bp)
      refute_enqueued(worker: SendBookingPaymentRefunded)

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LATE_TAKEN"))

      assert %{success: 1} = drain_payments()

      assert [%{form: form, headers: refund_headers}] = StripeStub.requests(:create_refund)
      assert form["charge"] == "ch_LATE_TAKEN"
      assert form["amount"] == Integer.to_string(bp.amount_cents)
      assert refund_headers["stripe-account"] == @account

      reloaded_bp = Repo.reload!(bp)
      assert reloaded_bp.status == :refunded
      assert reloaded_bp.refunded_amount_cents == bp.amount_cents

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == :expired

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

      StripeStub.stub(:retrieve_payment_intent, payment_intent("pi_LATE_AGAIN", "ch_LATE_AGAIN"))

      event = late_event("LATE_AGAIN", meeting)

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert :ok = CheckoutSessionCompleted.handle(event)
      assert :ok = CheckoutSessionCompleted.handle(%{event | "id" => "reconcile:cs_LATE_AGAIN"})

      assert [_one] = refunds(bp)
      assert [_job] = all_enqueued(worker: ExecuteRefund)
    end

    # The expiry released the invitation too, and it has been booked again at
    # another time: bringing the booking back would make a second live
    # booking on a single-use invitation, so the money goes back instead.
    test "refunds a completion that arrived after expiry once its invitation was booked again" do
      user = insert(:user)
      type = insert(:meeting_type, user: user, invitation_only: true)
      {:ok, invitation} = Invitations.create(user.id, type, %{})

      meeting =
        insert(:meeting,
          status: :expired,
          organizer_user_id: user.id,
          organizer_email: user.email,
          invitation_id: invitation.id
        )

      _rebooked =
        insert(:meeting,
          status: :confirmed,
          organizer_user_id: user.id,
          invitation_id: invitation.id,
          start_time: DateTime.add(meeting.start_time, 2, :day),
          end_time: DateTime.add(meeting.end_time, 2, :day)
        )

      bp =
        insert_payment(
          meeting: meeting,
          status: :failed,
          stripe_checkout_session_id: "cs_LATE_INVITED"
        )

      StripeStub.stub(
        :retrieve_payment_intent,
        payment_intent("pi_LATE_INVITED", "ch_LATE_INVITED")
      )

      assert :ok = CheckoutSessionCompleted.handle(late_event("LATE_INVITED", meeting))

      assert Repo.reload!(bp).status == :paid
      assert [%{source: :late_payment}] = refunds(bp)
      assert {:ok, %{status: :expired}} = MeetingQueries.get_meeting(meeting.id)
    end

    test "refunds a completion that arrived after expiry for a meeting whose organiser is gone" do
      meeting = insert(:meeting, status: :expired, organizer_user_id: nil)

      bp =
        insert_payment(
          meeting: meeting,
          status: :failed,
          stripe_checkout_session_id: "cs_LATE_ORPHAN"
        )

      StripeStub.stub(
        :retrieve_payment_intent,
        payment_intent("pi_LATE_ORPHAN", "ch_LATE_ORPHAN")
      )

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LATE_ORPHAN"))

      event =
        completed_event("evt_LATE_ORPHAN", %{
          "id" => "cs_LATE_ORPHAN",
          "client_reference_id" => meeting.id,
          "payment_intent" => "pi_LATE_ORPHAN"
        })

      assert :ok = CheckoutSessionCompleted.handle(event)
      assert %{success: 1} = drain_payments()

      assert [%{form: %{"charge" => "ch_LATE_ORPHAN"}}] = StripeStub.requests(:create_refund)
      assert Repo.reload!(bp).status == :refunded
      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == :expired
    end

    # The refund needs the charge id, which only Stripe can supply. Held back
    # until Stripe supplied it, the payment stayed `failed`, off the host's
    # outstanding refunds, once Stripe stopped redelivering. It is committed
    # paid with its refund instead, and each attempt backfills the charge id
    # first.
    test "records a late completion and its refund even when its charge cannot be found yet" do
      user = insert(:user)
      {meeting, bp} = taken_slot_booking(user, "LATE_NO_CHARGE")
      stripe_up = start_supervised!({Agent, fn -> false end})

      StripeStub.stub(:retrieve_payment_intent, fn request ->
        assert request.path == "/v1/payment_intents/pi_LATE_NO_CHARGE"
        assert request.headers["stripe-account"] == @account

        if Agent.get(stripe_up, & &1),
          do: payment_intent("pi_LATE_NO_CHARGE", "ch_LATE_NO_CHARGE"),
          else: {:error_fixture, "api_error"}
      end)

      event = late_event("LATE_NO_CHARGE", meeting)
      assert :ok = CheckoutSessionCompleted.handle(event)

      recorded = Repo.reload!(bp)
      assert recorded.status == :paid
      assert is_nil(recorded.stripe_charge_id)
      assert recorded.last_event_id == "evt_LATE_NO_CHARGE"
      assert [refund] = refunds(bp)
      bp_id = bp.id
      assert [%{id: ^bp_id}] = BookingPayments.list_outstanding_refunds_for_host(bp.host_user_id)

      # Stripe's redelivery and the reconciler's replay change nothing.
      assert :ok = CheckoutSessionCompleted.handle(event)

      assert :ok =
               CheckoutSessionCompleted.handle(%{event | "id" => "reconcile:cs_LATE_NO_CHARGE"})

      assert [^refund] = refunds(bp)
      assert Repo.reload!(bp).last_event_id == "evt_LATE_NO_CHARGE"

      # The refund waits while the charge id is still unavailable.
      assert {:error, :pending} =
               perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 1)

      assert Repo.reload!(bp).status == :paid

      Agent.update(stripe_up, fn _down -> true end)

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LATE_NO_CHARGE"))

      assert :ok = perform_job(ExecuteRefund, %{refund_id: refund.id}, attempt: 2)

      assert [%{form: form}] = StripeStub.requests(:create_refund)
      assert form["charge"] == "ch_LATE_NO_CHARGE"
      assert form["amount"] == Integer.to_string(bp.amount_cents)

      refunded = Repo.reload!(bp)
      assert refunded.status == :refunded
      assert refunded.stripe_charge_id == "ch_LATE_NO_CHARGE"

      {:ok, reloaded_meeting} = MeetingQueries.get_meeting(meeting.id)
      assert reloaded_meeting.status == :expired
    end
  end

  # An expired booking whose slot another confirmed booking now holds.
  # The attendee disputes the late payment before its refund is made, so
  # Stripe refuses the refund. When the host wins, the money is back with
  # them for a booking that never happened, and is refunded after all.
  describe "a late payment disputed before its refund" do
    test "is refunded, once, after the host wins the dispute" do
      user = insert(:user)
      {meeting, bp} = taken_slot_booking(user, "LATE_DISPUTED")

      StripeStub.stub(
        :retrieve_payment_intent,
        payment_intent("pi_LATE_DISPUTED", "ch_LATE_DISPUTED")
      )

      assert :ok = CheckoutSessionCompleted.handle(late_event("LATE_DISPUTED", meeting))

      assert :ok =
               ChargeDisputeCreated.handle(
                 dispute_event("evt_DISPUTE_OPENED", "charge.dispute.created", %{
                   "reason" => "fraudulent"
                 })
               )

      StripeStub.expect(:create_refund, {:error_fixture, "invalid_request_error"})
      assert %{cancelled: 1} = drain_payments()
      assert Repo.reload!(bp).status == :disputed

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_LATE_DISPUTED"))

      assert %{success: 1} = drain_payments()

      assert [_refused, %{form: form}] = StripeStub.requests(:create_refund)
      assert form["charge"] == "ch_LATE_DISPUTED"
      assert form["amount"] == Integer.to_string(bp.amount_cents)

      assert Repo.reload!(bp).status == :refunded
      assert {:ok, %{status: :expired}} = MeetingQueries.get_meeting(meeting.id)

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

      assert bp |> refunds() |> Enum.map(&{&1.status, &1.amount_cents}) |> Enum.sort() ==
               [{:failed, 5000}, {:succeeded, 5000}]
    end

    # An inquiry escalates into a chargeback, and the inquiry's close
    # arrives after the chargeback opened. The money is still held by the
    # chargeback, so nothing is refunded until that one closes.
    test "is not refunded by a late close of the inquiry its chargeback replaced" do
      bp = disputed_expired_payment(refunded_amount_cents: 0, stripe_dispute_id: "dp_INQUIRY")

      assert :ok =
               ChargeDisputeCreated.handle(
                 dispute_event("evt_CHARGEBACK_OPENED", "charge.dispute.created", %{
                   "id" => "dp_CHARGEBACK",
                   "status" => "needs_response",
                   "reason" => "fraudulent"
                 })
               )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_INQUIRY_CLOSED", "charge.dispute.closed", %{
                   "id" => "dp_INQUIRY",
                   "status" => "warning_closed"
                 })
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.stripe_dispute_id == "dp_CHARGEBACK"
      assert refunds(bp) == []

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_CHARGEBACK_WON", "charge.dispute.closed", %{
                   "id" => "dp_CHARGEBACK",
                   "status" => "won"
                 })
               )

      assert Repo.reload!(bp).status == :paid
      assert [%{source: :late_payment, amount_cents: 5000}] = refunds(bp)
    end

    test "is refunded after a won dispute whose created Stripe delivers late" do
      bp =
        disputed_expired_payment(refunded_amount_cents: 0, stripe_dispute_id: "dp_LATE_DISPUTED")

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      # The retried created carries the status it was created with.
      assert :ok =
               ChargeDisputeCreated.handle(
                 dispute_event("evt_DISPUTE_OPENED", "charge.dispute.created", %{
                   "status" => "needs_response",
                   "reason" => "fraudulent"
                 })
               )

      assert Repo.reload!(bp).status == :paid
      assert_remainder_refunded(bp, 5000)
    end

    # Whatever the dispute decided, what is left with the host for a booking
    # that never happened goes back to the attendee.
    test "refunds what is left after a won dispute on a partly refunded payment" do
      bp = disputed_expired_payment(refunded_amount_cents: 1500)

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      assert Repo.reload!(bp).status == :partially_refunded
      assert_remainder_refunded(bp, 3500)
    end

    for status <- ["warning_closed", "prevented"] do
      test "refunds the payment in full after an inquiry closed as #{status}" do
        bp = disputed_expired_payment(refunded_amount_cents: 0)

        assert :ok =
                 ChargeDisputeClosed.handle(
                   dispute_event("evt_DISPUTE_INQUIRY", "charge.dispute.closed", %{
                     "status" => unquote(status)
                   })
                 )

        assert Repo.reload!(bp).status == :paid
        assert_remainder_refunded(bp, 5000)
      end
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

      assert %{status: :partially_refunded, refunded_amount_cents: 2000} = Repo.reload!(bp)
      assert_remainder_refunded(bp, 3000)
    end

    test "schedules no refund for a dispute the host wins on a booking that went ahead" do
      meeting = insert(:meeting, status: :confirmed)

      insert_payment(
        meeting: meeting,
        status: :disputed,
        paid_at: DateTime.utc_now(:second),
        stripe_charge_id: "ch_LATE_DISPUTED"
      )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      assert Repo.all(RefundSchema) == []
    end

    # A paid booking whose reschedule request lapsed went ahead as far as the
    # payment is concerned: its refund is the host's call, not the dispute's.
    test "schedules no refund for a won dispute on a booking whose reschedule request lapsed" do
      meeting =
        insert(:meeting,
          status: :expired,
          reschedule_requested_at: DateTime.add(DateTime.utc_now(:second), -8, :day)
        )

      bp =
        insert_payment(
          meeting: meeting,
          status: :disputed,
          amount_cents: 5000,
          paid_at: DateTime.add(DateTime.utc_now(:second), -10, :day),
          stripe_charge_id: "ch_LATE_DISPUTED"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_event("evt_DISPUTE_WON", "charge.dispute.closed", %{"status" => "won"})
               )

      assert Repo.reload!(bp).status == :paid
      assert Repo.all(RefundSchema) == []
    end
  end

  defp disputed_expired_payment(attrs) do
    meeting = insert(:meeting, status: :expired)

    insert_payment(
      [
        meeting: meeting,
        status: :disputed,
        amount_cents: 5000,
        paid_at: DateTime.utc_now(:second),
        stripe_charge_id: "ch_LATE_DISPUTED"
      ] ++ attrs
    )
  end

  defp assert_remainder_refunded(bp, remainder) do
    StripeStub.expect(
      :create_refund,
      StripeStubResponses.refund("re_#{bp.id}", bp.refunded_amount_cents)
    )

    assert %{success: 1} = drain_payments()

    assert [%{form: form}] = StripeStub.requests(:create_refund)
    assert form["charge"] == "ch_LATE_DISPUTED"
    assert form["amount"] == Integer.to_string(remainder)
    assert %{status: :refunded, refunded_amount_cents: 5000} = Repo.reload!(bp)
  end

  defp refunds(bp), do: Repo.all(from(r in RefundSchema, where: r.booking_payment_id == ^bp.id))

  # A recorded refund's job is due at once.
  defp drain_payments, do: Oban.drain_queue(queue: :payments, with_scheduled: true)

  defp payment_intent(id, charge_id) do
    StripeFixtures.object("payment_intent_with_latest_charge", %{
      "id" => id,
      "latest_charge" => %{"id" => charge_id}
    })
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
        status: :expired,
        organizer_user_id: user.id,
        organizer_email: user.email
      )

    _taker =
      insert(:meeting,
        status: :confirmed,
        organizer_user_id: user.id,
        start_time: meeting.start_time,
        end_time: meeting.end_time
      )

    payment =
      insert_payment(
        meeting: meeting,
        status: :failed,
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
