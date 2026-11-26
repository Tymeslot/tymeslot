defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  # Every booking_payment is charged on this connected account, and every
  # event arrives from it, as Stripe delivers them for a genuine booking.
  @account "acct_TEST_HOST"

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Stripe.Error, as: StripeError
  alias Tymeslot.MeetingPayments.RefundedTotal
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Repo
  alias Tymeslot.StripeStub

  describe "handle/1 — won outcomes" do
    test "won dispute on a previously paid booking reverts status to paid" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_WON"
        )

      event = dispute_closed_event("evt_WON", "ch_WON", "won", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :paid
    end

    test "won dispute preserves prior partial refunds and reverts to partially_refunded" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 1500,
          stripe_charge_id: "ch_WON_PART"
        )

      event = dispute_closed_event("evt_WON_PART", "ch_WON_PART", "won", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :partially_refunded
      assert reloaded.refunded_amount_cents == 1500
    end
  end

  # An inquiry Stripe closes without a chargeback (`warning_closed`), or one
  # stopped before it became one (`prevented`), is final and takes no funds.
  describe "handle/1 — inquiries closed without a chargeback" do
    for status <- ["warning_closed", "prevented"] do
      test "#{status} reverts a disputed booking to paid" do
        bp =
          insert(:booking_payment,
            stripe_account_id: @account,
            status: :disputed,
            amount_cents: 5000,
            refunded_amount_cents: 0,
            stripe_charge_id: "ch_#{unquote(status)}"
          )

        event =
          dispute_closed_event(
            "evt_#{unquote(status)}",
            "ch_#{unquote(status)}",
            unquote(status),
            5000
          )

        assert :ok = ChargeDisputeClosed.handle(event)

        reloaded = Repo.reload!(bp)
        assert reloaded.status == :paid
        assert reloaded.refunded_amount_cents == 0
        assert reloaded.last_event_id == "evt_#{unquote(status)}"
      end

      test "#{status} keeps a prior partial refund as partially_refunded" do
        bp =
          insert(:booking_payment,
            stripe_account_id: @account,
            status: :disputed,
            amount_cents: 5000,
            refunded_amount_cents: 1500,
            stripe_charge_id: "ch_PART_#{unquote(status)}"
          )

        event =
          dispute_closed_event(
            "evt_PART_#{unquote(status)}",
            "ch_PART_#{unquote(status)}",
            unquote(status),
            5000
          )

        assert :ok = ChargeDisputeClosed.handle(event)

        reloaded = Repo.reload!(bp)
        assert reloaded.status == :partially_refunded
        assert reloaded.refunded_amount_cents == 1500
      end
    end
  end

  describe "handle/1 — lost outcomes" do
    test "lost dispute on full charge marks the booking refunded with the disputed amount" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_LOST"
        )

      event = dispute_closed_event("evt_LOST", "ch_LOST", "lost", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
    end

    test "lost partial dispute marks the booking partially_refunded" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_LOST_PART"
        )

      event = dispute_closed_event("evt_LOST_PART", "ch_LOST_PART", "lost", 2000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :partially_refunded
      assert reloaded.refunded_amount_cents == 2000
      assert reloaded.disputed_lost_cents == 2000
    end

    # Refunds and a lost dispute are different money: the dispute is added
    # to what was refunded before it, not compared with it.
    test "a lost dispute adds to the refunds made before it" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 1000,
          stripe_charge_id: "ch_LOST_AFTER_REFUND"
        )

      event = dispute_closed_event("evt_LOST_AFTER_REFUND", "ch_LOST_AFTER_REFUND", "lost", 2000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :partially_refunded
      assert reloaded.refunded_amount_cents == 3000
      assert reloaded.disputed_lost_cents == 2000
    end

    test "a lost dispute over money already refunded settles at the amount paid" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 2000,
          stripe_charge_id: "ch_LOST_TWICE"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_LOST_TWICE", "ch_LOST_TWICE", "lost", 5000)
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.disputed_lost_cents == 5000
    end

    test "a lost dispute over a fully refunded charge keeps the refunds made" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 5000,
          stripe_charge_id: "ch_REFUNDED_THEN_LOST"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event(
                   "evt_REFUNDED_THEN_LOST",
                   "ch_REFUNDED_THEN_LOST",
                   "lost",
                   5000
                 )
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.disputed_lost_cents == 5000
      assert RefundedTotal.stripe_refunded_cents(reloaded) == 5000
    end
  end

  describe "handle/1 — bookkeeping" do
    test "is idempotent on event id" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_REPLAY",
          last_event_id: "evt_REPLAY"
        )

      event = dispute_closed_event("evt_REPLAY", "ch_REPLAY", "won", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      # Untouched (last_event_id matched)
      assert reloaded.status == :paid
    end

    test "leaves a live dispute status disputed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_LIVE"
        )

      event = dispute_closed_event("evt_LIVE", "ch_LIVE", "warning_under_review", 5000)

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.last_event_id == nil
    end

    test "returns :ok when no booking_payment matches the charge id" do
      event = dispute_closed_event("evt_NOMATCH", "ch_GHOST", "won", 5000)
      assert :ok = ChargeDisputeClosed.handle(event)
    end
  end

  describe "handle/1 — recording the closed dispute" do
    test "a final outcome records the dispute as closed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_RECORD",
          stripe_dispute_id: "dp_evt_RECORD"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_RECORD", "ch_RECORD", "won", 5000)
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.stripe_dispute_id == "dp_evt_RECORD"
      assert %DateTime{} = reloaded.dispute_closed_at
    end

    # A closed that overtakes its created must still record its outcome:
    # a lost dispute's refunded amount would otherwise never be written.
    test "a closed delivered before its created is applied to a paid payment" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: "ch_EARLY_LOST"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_EARLY_LOST", "ch_EARLY_LOST", "lost", 5000)
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000
      assert reloaded.stripe_dispute_id == "dp_evt_EARLY_LOST"
      assert %DateTime{} = reloaded.dispute_closed_at
    end

    test "a live dispute status records nothing" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_LIVE_REC",
          stripe_dispute_id: "dp_evt_LIVE_REC"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_LIVE_REC", "ch_LIVE_REC", "needs_response", 5000)
               )

      assert Repo.reload!(bp).dispute_closed_at == nil
    end
  end

  # Stripe can deliver the close of an earlier dispute (an inquiry closed
  # as `warning_closed`) after the chargeback it escalated into was opened.
  describe "handle/1 — a close for a different dispute than the one open" do
    test "leaves the payment disputed with the open dispute" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_OTHER",
          stripe_dispute_id: "dp_OPEN_B",
          last_event_id: "evt_CREATED_B"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_INQUIRY_A", "ch_OTHER", "warning_closed", 5000)
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.stripe_dispute_id == "dp_OPEN_B"
      assert reloaded.dispute_closed_at == nil
      assert reloaded.last_event_id == "evt_CREATED_B"
    end

    test "the open dispute's own close still applies" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_OWN",
          stripe_dispute_id: "dp_evt_OWN"
        )

      assert :ok =
               ChargeDisputeClosed.handle(dispute_closed_event("evt_OWN", "ch_OWN", "lost", 5000))

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert %DateTime{} = reloaded.dispute_closed_at
    end

    test "a close for a new dispute applies after an earlier one closed" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :paid,
          amount_cents: 5000,
          stripe_charge_id: "ch_SECOND",
          stripe_dispute_id: "dp_CLOSED_A",
          dispute_closed_at: ~U[2026-11-01 10:00:00Z]
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_SECOND", "ch_SECOND", "lost", 5000)
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :refunded
      assert reloaded.stripe_dispute_id == "dp_evt_SECOND"
    end

    # Disputes open on the day dispute tracking shipped carry no id; they
    # must still close, or they would stay disputed for good.
    test "a payment with no recorded dispute is closed by any dispute" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_LEGACY",
          stripe_dispute_id: nil
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_LEGACY", "ch_LEGACY", "won", 5000)
               )

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :paid
      assert reloaded.stripe_dispute_id == "dp_evt_LEGACY"
      assert %DateTime{} = reloaded.dispute_closed_at
    end
  end

  describe "handle/1 when the row is found only through Stripe" do
    test "a transient intent lookup answers retry_later and records no outcome" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          refunded_amount_cents: 0,
          stripe_charge_id: nil,
          stripe_payment_intent_id: nil
        )

      StripeStub.stub(:retrieve_payment_intent, {:error_fixture, "rate_limit"})

      event =
        "evt_CLOSED_BLIP"
        |> dispute_closed_event("ch_x", "lost", 5000)
        |> put_in(["data", "object", "payment_intent"], "pi_x")

      assert {:error, :retry_later, %StripeError{status: 429}} = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.last_event_id == nil
    end
  end

  describe "handle/1 with an event from another connected account" do
    test "leaves the disputed booking payment untouched" do
      bp =
        insert(:booking_payment,
          stripe_account_id: @account,
          status: :disputed,
          amount_cents: 5000,
          stripe_charge_id: "ch_FOREIGN_CLOSED"
        )

      event =
        "evt_FOREIGN_CLOSED"
        |> dispute_closed_event("ch_FOREIGN_CLOSED", "lost", 5000)
        |> Map.put("account", "acct_ATTACKER")

      assert :ok = ChargeDisputeClosed.handle(event)

      reloaded = Repo.reload!(bp)
      assert reloaded.status == :disputed
      assert reloaded.refunded_amount_cents == 0
      assert reloaded.last_event_id == nil
    end
  end

  # A request released through the approval gate while a dispute held its
  # payment: the release's own refund was refused, so the dispute's close
  # applies the release's rule. The attendee is owed all of a request that
  # was never a meeting; one that had been a meeting before a reschedule
  # sent it back through the gate is left to its host.
  describe "handle/1 for a paid request released through the approval gate" do
    test "refunds all of a request declined while its payment was disputed" do
      {meeting, bp} = disputed_request("ch_DECLINED")

      assert {:ok, %{status: :cancelled}} = Approval.decline(meeting, "Fully booked")
      assert RefundQueries.list_for_payment(bp.id) == []

      assert :ok = ChargeDisputeClosed.handle(won_event("evt_DECLINED_WON", "ch_DECLINED"))

      assert [%{amount_cents: 5000, status: :pending} = refund] =
               RefundQueries.list_for_payment(bp.id)

      assert_enqueued(worker: ExecuteRefund, args: %{refund_id: refund.id})
    end

    test "refunds all of a request withdrawn while its payment was disputed" do
      {meeting, bp} = disputed_request("ch_WITHDRAWN")

      assert {:ok, %{status: :cancelled}} = Approval.withdraw(meeting)

      assert :ok = ChargeDisputeClosed.handle(won_event("evt_WITHDRAWN_WON", "ch_WITHDRAWN"))

      assert [%{amount_cents: 5000, status: :pending}] = RefundQueries.list_for_payment(bp.id)
    end

    test "leaves the refund to the host when a rescheduled meeting's request expires" do
      {meeting, bp} =
        disputed_request("ch_REREQUESTED",
          first_announced_at: DateTime.add(DateTime.utc_now(:second), -3, :day)
        )

      assert {:ok, %{status: :expired}} = Approval.expire(meeting)

      assert :ok =
               ChargeDisputeClosed.handle(won_event("evt_REREQUESTED_WON", "ch_REREQUESTED"))

      assert Repo.reload!(bp).status == :paid
      assert RefundQueries.list_for_payment(bp.id) == []
      refute_enqueued(worker: ExecuteRefund)
    end

    test "leaves the refund to the host for an approved booking cancelled later" do
      now = DateTime.utc_now(:second)

      meeting =
        insert(:meeting,
          status: :cancelled,
          approval_requested_at: DateTime.add(now, -3, :day),
          approval_resolved_at: DateTime.add(now, -2, :day),
          cancelled_at: DateTime.add(now, -1, :day)
        )

      bp = disputed_payment(meeting, "ch_APPROVED_CANCELLED")

      assert :ok =
               ChargeDisputeClosed.handle(
                 won_event("evt_APPROVED_CANCELLED_WON", "ch_APPROVED_CANCELLED")
               )

      assert Repo.reload!(bp).status == :paid
      assert RefundQueries.list_for_payment(bp.id) == []
    end
  end

  defp disputed_request(charge_id, attrs \\ []) do
    user = insert(:user)
    now = DateTime.utc_now(:second)

    meeting =
      insert(
        :meeting,
        [
          status: :awaiting_approval,
          organizer_user: user,
          organizer_user_id: user.id,
          approval_requested_at: now,
          approval_deadline_at: DateTime.add(now, 24, :hour)
        ] ++ attrs
      )

    {meeting, disputed_payment(meeting, charge_id)}
  end

  defp disputed_payment(meeting, charge_id) do
    insert(:booking_payment,
      meeting_id: meeting.id,
      stripe_account_id: @account,
      stripe_charge_id: charge_id,
      status: :disputed,
      amount_cents: 5000,
      refunded_amount_cents: 0,
      paid_at: DateTime.add(DateTime.utc_now(:second), -4, :day)
    )
  end

  defp won_event(event_id, charge_id), do: dispute_closed_event(event_id, charge_id, "won", 5000)

  defp dispute_closed_event(event_id, charge_id, dispute_status, amount) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "charge.dispute.closed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "dp_#{event_id}",
          "object" => "dispute",
          "charge" => charge_id,
          "amount" => amount,
          "status" => dispute_status
        }
      }
    }
  end
end
