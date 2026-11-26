defmodule Tymeslot.Meetings.CancellationGroupRaceTest do
  @moduledoc """
  The host cancelling a paid group session while a seat is being paid, or
  a seat's payment changes: the seat paid while the cancellation waited on
  the meeting's row lock is refunded too, and each seat's refund is sized
  from the payment as it stands once the cancellation holds its row lock.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.GroupCancellationTestHelpers
  import Tymeslot.Test.RaceConductor, only: [unboxed: 1]

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context -> {:error, :none} end)
    :ok
  end

  setup do
    ctx = unboxed(fn -> host_and_session() end)

    on_exit(fn ->
      unboxed(fn ->
        payment_ids =
          Repo.all(
            from(p in BookingPaymentSchema,
              where: p.host_user_id == ^ctx.host.id,
              select: p.id
            )
          )

        refund_ids =
          Repo.all(
            from(r in RefundSchema, where: r.booking_payment_id in ^payment_ids, select: r.id)
          )

        Repo.delete_all(
          from(j in Oban.Job,
            where:
              fragment("?->>'meeting_id'", j.args) == ^ctx.session.id or
                fragment("?->>'booking_payment_id'", j.args) in ^payment_ids or
                fragment("?->>'refund_id'", j.args) in ^refund_ids
          )
        )

        Repo.delete_all(from(r in RefundSchema, where: r.id in ^refund_ids))

        Repo.delete_all(from(p in BookingPaymentSchema, where: p.host_user_id == ^ctx.host.id))
        Repo.delete_all(from(m in MeetingSchema, where: m.organizer_user_id == ^ctx.host.id))
        Repo.delete_all(from(u in UserSchema, where: u.id == ^ctx.host.id))
      end)
    end)

    ctx
  end

  describe "a seat paid while the cancellation waited" do
    # The conversion holds the meeting's row lock while it books the seat
    # and settles its payment; the cancellation waits on that lock, then
    # reads the seat payments, and finds the one just paid.
    test "is refunded too", ctx do
      hold =
        unboxed(fn ->
          paid_seat(ctx, "ada@example.com")
          hold = open_hold(ctx, "late@example.com")
          hold
        end)

      test_pid = self()

      conversion =
        Task.async(fn ->
          unboxed(fn ->
            Repo.transaction(fn ->
              {:ok, booking} =
                GroupScheduling.convert_hold(hold.id,
                  new_slot: fn _hold, _meeting -> :none end,
                  on_booked: RaceConductor.park_here(test_pid)
                )

              payment = BookingPayments.payment_for_seat_hold(hold.id)

              payment
              |> Changeset.change(
                status: :paid,
                paid_at: DateTime.utc_now(:second),
                stripe_charge_id: "ch_late",
                participant_id: booking.participant.id
              )
              |> Repo.update!()
            end)
          end)
        end)

      assert_receive {:parked, converter}, 5_000

      cancellation =
        Task.async(fn ->
          unboxed(fn ->
            Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)
          end)
        end)

      assert :blocked = RaceConductor.await_finished_or_blocked(cancellation)
      send(converter, :release)

      assert {:ok, _paid} = Task.await(conversion)
      assert {:ok, _cancelled} = Task.await(cancellation)

      late_payment = unboxed(fn -> BookingPayments.payment_for_seat_hold(hold.id) end)

      refunded_ids =
        unboxed(fn ->
          Repo.all(
            from(r in RefundSchema,
              where: r.source == :cancellation,
              select: r.booking_payment_id
            )
          )
        end)

      assert late_payment.id in refunded_ids
      assert length(refunded_ids) == 2
    end
  end

  # Another writer holds the seat's payment row, as a refund settling on
  # the payments page or a dispute event does, while the cancellation
  # starts: it reads the seat as it was, then waits on that row lock to
  # record its refund, and finds the payment changed once it gets it.
  defp cancel_while_payment_changes(ctx, payment, changes) do
    test_pid = self()

    writer =
      Task.async(fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            payment |> Changeset.change(changes) |> Repo.update!()
            RaceConductor.park_here(test_pid).(nil)
          end)
        end)
      end)

    assert_receive {:parked, parked_writer}, 5_000

    cancellation =
      Task.async(fn ->
        unboxed(fn ->
          Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)
        end)
      end)

    assert :blocked = RaceConductor.await_finished_or_blocked(cancellation)
    send(parked_writer, :release)
    assert {:ok, _changed} = Task.await(writer)

    Task.await(cancellation)
  end

  defp refunds(payment), do: unboxed(fn -> RefundQueries.list_for_payment(payment.id) end)

  describe "a seat's payment changed while the cancellation waited" do
    test "refunds only what a refund settled meanwhile left", ctx do
      payment = unboxed(fn -> paid_seat(ctx, "ada@example.com") end)

      assert {:ok, _cancelled} =
               cancel_while_payment_changes(ctx, payment,
                 status: :partially_refunded,
                 refunded_amount_cents: 500
               )

      assert [%{source: :cancellation, status: :pending, amount_cents: 1500} = refund] =
               refunds(payment)

      assert refund.requested_by_user_id == ctx.host.id
    end

    test "records no refund of a seat refunded in full meanwhile", ctx do
      payment = unboxed(fn -> paid_seat(ctx, "ada@example.com") end)

      assert {:ok, _cancelled} =
               cancel_while_payment_changes(ctx, payment,
                 status: :refunded,
                 refunded_amount_cents: price_cents()
               )

      assert refunds(payment) == []
    end

    test "holds back the refund of a seat disputed meanwhile", ctx do
      payment = unboxed(fn -> paid_seat(ctx, "ada@example.com") end)

      assert {:ok, _cancelled} = cancel_while_payment_changes(ctx, payment, status: :disputed)

      assert [
               %{
                 source: :cancellation,
                 status: :failed,
                 failure_code: "under_dispute",
                 amount_cents: 2000
               }
             ] = refunds(payment)
    end

    # The seat is read disputed, and its dispute closes in the host's
    # favour before the cancellation locks it: the cancellation records a
    # refund to make, which the dispute's close, having found none, could
    # not have asked for.
    test "refunds a seat whose dispute was won meanwhile", ctx do
      payment =
        unboxed(fn -> paid_seat(ctx, "ada@example.com", status: :disputed) end)

      assert {:ok, _cancelled} = cancel_while_payment_changes(ctx, payment, status: :paid)

      assert [%{source: :cancellation, status: :pending, amount_cents: 2000} = refund] =
               refunds(payment)

      unboxed(fn -> assert_enqueued(worker: ExecuteRefund, args: %{refund_id: refund.id}) end)
    end
  end
end
