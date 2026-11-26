defmodule Tymeslot.Meetings.CancellationGroupRaceTest do
  @moduledoc """
  The host cancelling a paid group session while a seat is being paid:
  the seat paid while the cancellation waited on the meeting's row lock
  is refunded too.
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
  alias Tymeslot.MeetingPayments.RefundSchema
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

  describe "a seat paid while the cancellation waited" do
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
end
