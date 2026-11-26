defmodule Tymeslot.Meetings.CancellationGroupDisputeTest do
  @moduledoc """
  The host cancelling a paid group session while a seat's payment is under
  dispute: the seat is not refunded then, but its refund is recorded held
  back by the dispute, so a dispute the host later wins refunds the
  attendee what came back. A host who chose no refund records none.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.GroupCancellationTestHelpers

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Meetings
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @account Tymeslot.GroupCancellationTestHelpers.account()

  setup do
    TestMocks.setup_calendar_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :none}
    end)

    :ok
  end

  defp disputed_seat(ctx, email, charge_id) do
    paid_seat(ctx, email, status: :disputed, stripe_charge_id: charge_id)
  end

  defp close_dispute(charge_id, dispute_status, amount) do
    ChargeDisputeClosed.handle(%{
      "id" => "evt_closed_#{charge_id}",
      "account" => @account,
      "type" => "charge.dispute.closed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "dp_#{charge_id}",
          "object" => "dispute",
          "charge" => charge_id,
          "amount" => amount,
          "status" => dispute_status
        }
      }
    })
  end

  defp refunds(payment), do: RefundQueries.list_for_payment(payment.id)

  test "a disputed seat is refunded once the host who cancelled wins the dispute" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    disputed = disputed_seat(ctx, "grace@example.com", "ch_GRACE")

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    assert [%{status: :failed, source: :cancellation, amount_cents: 2000}] = refunds(disputed)
    refute_enqueued(worker: ExecuteRefund, args: %{booking_payment_id: disputed.id})

    assert :ok = close_dispute("ch_GRACE", "won", 2000)

    assert [%{status: :failed}, %{status: :pending, amount_cents: 2000} = refund] =
             Enum.sort_by(refunds(disputed), &(&1.status != :failed))

    assert_enqueued(worker: ExecuteRefund, args: %{refund_id: refund.id})
  end

  test "a partly lost dispute refunds only what came back to the host" do
    ctx = host_and_session()
    disputed = disputed_seat(ctx, "grace@example.com", "ch_PART")

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    assert :ok = close_dispute("ch_PART", "lost", 1500)

    assert [%{amount_cents: 500}] = Enum.filter(refunds(disputed), &(&1.status == :pending))
  end

  test "a host who chose no refund leaves the seat theirs after a won dispute" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    disputed = disputed_seat(ctx, "grace@example.com", "ch_NONE")

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert refunds(disputed) == []

    assert :ok = close_dispute("ch_NONE", "won", 2000)

    assert refunds(disputed) == []
    assert Repo.reload!(disputed).status == :paid
  end

  # With every paid seat disputed the dialog offers no choice, which the
  # dashboard resolves to `:none` (`Meetings.resolve_seat_refund/2`): the
  # default, a full refund, applies to the disputed seats.
  test "a session whose only paid seats are disputed records their refunds" do
    ctx = host_and_session()
    disputed = disputed_seat(ctx, "grace@example.com", "ch_ONLY")

    assert {:ok, :none} =
             Meetings.resolve_seat_refund(
               BookingPayments.seat_payments_for_meeting(
                 ctx.session.id,
                 ctx.host.id
               ),
               %{}
             )

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert [%{status: :failed, source: :cancellation}] = refunds(disputed)

    assert :ok = close_dispute("ch_ONLY", "won", 2000)
    assert Enum.any?(refunds(disputed), &(&1.status == :pending))
  end

  test "a won dispute on a session still going ahead refunds nothing" do
    ctx = host_and_session()
    disputed = disputed_seat(ctx, "grace@example.com", "ch_LIVE")

    assert :ok = close_dispute("ch_LIVE", "won", 2000)

    assert refunds(disputed) == []
  end

  # One read classifies every live seat, so a seat cannot fall between a
  # read of the refundable seats and another of the disputed ones.
  test "one read of the live seats splits the refundable from the disputed" do
    ctx = host_and_session()
    earlier = ~U[2026-11-01 10:00:00Z]
    paid = paid_seat(ctx, "ada@example.com", inserted_at: earlier)
    disputed = disputed_seat(ctx, "grace@example.com", "ch_SPLIT")

    partly =
      paid_seat(ctx, "alan@example.com",
        status: :partially_refunded,
        refunded_amount_cents: 500,
        inserted_at: DateTime.add(earlier, 1, :hour)
      )

    paid_seat(ctx, "edsger@example.com", status: :refunded, refunded_amount_cents: 2000)
    paid_seat(ctx, "mallory@example.com", host_user_id: insert(:user).id, status: :disputed)

    assert {outstanding, disputed_seats} =
             BookingPayments.live_seat_payments_for_meeting(ctx.session.id, ctx.host.id)

    assert Enum.map(outstanding, & &1.id) == [paid.id, partly.id]
    assert Enum.map(disputed_seats, & &1.id) == [disputed.id]

    assert ctx.session.id
           |> BookingPayments.seat_payments_for_meeting(ctx.host.id)
           |> Enum.map(& &1.id) == [paid.id, partly.id]
  end
end
