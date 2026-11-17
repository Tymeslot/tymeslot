defmodule Tymeslot.Meetings.CancellationGroupTest do
  @moduledoc """
  The host cancelling a paid group session: every paid seat refunded in
  full through one job each (`Workers.GroupCancelRefund`), or none with the
  acknowledgement, and every seat still held for a booker paying released
  with its checkout expired.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :bookings
  @moduletag :integration

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory
  import Tymeslot.Test.RaceConductor, only: [unboxed: 1]

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.MeetingPayments.Workers.GroupCancelRefund
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Repo
  alias Tymeslot.Test.RaceConductor
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  @account "acct_GROUP_CANCEL"
  @price 2000

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()
    stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context -> {:error, :none} end)
    :ok
  end

  defp host_and_session(attrs \\ []) do
    host = insert(:user, email: "host@example.com", name: "Host")
    insert(:profile, user: host, timezone: "Etc/UTC")

    meeting_type =
      insert(:meeting_type,
        user: host,
        name: "Group Class",
        max_participants: 6,
        payment_required: true,
        price_cents: @price
      )

    start_time =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> then(&%{&1 | hour: 10, minute: 0, second: 0, microsecond: {0, 0}})

    session =
      insert(
        :group_meeting,
        Keyword.merge(
          [
            organizer_user: host,
            organizer_email: host.email,
            meeting_type_ref: meeting_type,
            title: meeting_type.name,
            start_time: start_time,
            end_time: DateTime.add(start_time, 30, :minute),
            duration: 30,
            capacity: 6,
            status: :confirmed
          ],
          attrs
        )
      )

    %{host: host, meeting_type: meeting_type, session: session}
  end

  defp paid_seat(%{host: host, session: session}, email, payment_attrs \\ []) do
    participant = insert(:participant, meeting: session, email: email)
    hold = insert(:seat_hold, meeting: session, email: email, status: :converted)

    insert(
      :paid_booking_payment,
      Keyword.merge(
        [
          meeting_id: session.id,
          participant_id: participant.id,
          seat_hold_id: hold.id,
          seat_payment: true,
          seats: 1,
          amount_cents: @price,
          host_user_id: host.id,
          host_email: host.email,
          attendee_email: email,
          stripe_account_id: @account
        ],
        payment_attrs
      )
    )
  end

  defp open_hold(%{host: host, session: session}, email) do
    hold = insert(:seat_hold, meeting: session, email: email)

    insert(:booking_payment,
      meeting_id: session.id,
      seat_hold_id: hold.id,
      seat_payment: true,
      seats: 1,
      amount_cents: @price,
      host_user_id: host.id,
      stripe_account_id: @account,
      stripe_checkout_session_id: "cs_open_#{hold.id}"
    )

    hold
  end

  defp refund_amounts do
    [worker: GroupCancelRefund]
    |> all_enqueued()
    |> Enum.map(& &1.args["amount_cents"])
    |> Enum.sort()
  end

  defp status(meeting), do: Repo.get!(MeetingSchema, meeting.id).status

  test "cancelling a paid group meeting schedules one refund per paid seat" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    paid_seat(ctx, "grace@example.com")

    paid_seat(ctx, "alan@example.com",
      status: :partially_refunded,
      refunded_amount_cents: 500
    )

    assert {:ok, cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    assert cancelled.status == :cancelled
    assert status(ctx.session) == :cancelled
    assert refund_amounts() == [1500, 2000, 2000]

    assert [%{args: %{"seat_refund" => "full"}}] =
             all_enqueued(worker: EmailWorker, args: %{action: "send_cancellation_emails"})
  end

  test "the dialog's choice: every seat in full, or none with the acknowledgement" do
    ctx = host_and_session()
    payment = paid_seat(ctx, "ada@example.com")
    payments = BookingPayments.seat_payments_for_meeting(ctx.session.id, ctx.host.id)
    assert Enum.map(payments, & &1.id) == [payment.id]

    assert {:ok, :refund_seats} = Meetings.resolve_seat_refund(payments, %{})

    assert {:ok, :refund_seats} =
             Meetings.resolve_seat_refund(payments, %{
               "cancel_refund_choice" => "partial",
               "cancel_refund_amount" => "5.00"
             })

    assert {:error, :acknowledgement_required} =
             Meetings.resolve_seat_refund(payments, %{"cancel_refund_choice" => "none"})

    assert {:ok, :none} =
             Meetings.resolve_seat_refund(payments, %{
               "cancel_refund_choice" => "none",
               "cancel_refund_no_refund_ack" => "true"
             })

    assert {:ok, :none} = Meetings.resolve_seat_refund([], %{"cancel_refund_choice" => "none"})
  end

  test "no refund cancels without a refund job" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert status(ctx.session) == :cancelled
    assert refund_amounts() == []

    assert [%{args: %{"seat_refund" => "none"}}] =
             all_enqueued(worker: EmailWorker, args: %{action: "send_cancellation_emails"})
  end

  test "a partial choice refunds every seat in full" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    paid_seat(ctx, "grace@example.com")

    {:ok, action} =
      ctx.session.id
      |> BookingPayments.seat_payments_for_meeting(ctx.host.id)
      |> Meetings.resolve_seat_refund(%{
        "cancel_refund_choice" => "partial",
        "cancel_refund_amount" => "5.00"
      })

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, action)

    assert refund_amounts() == [2000, 2000]
  end

  test "open holds are released and their checkouts expired" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    hold = open_hold(ctx, "late@example.com")
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))
    session_id = "cs_open_#{hold.id}"

    expect(StripeAdapterMock, :expire_checkout_session, fn ^session_id, opts ->
      assert opts[:connect_account] == @account
      {:ok, %{"id" => session_id, "status" => "expired"}}
    end)

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert %{status: :released, released_reason: :meeting_cancelled} = SeatHolds.get(hold.id)
    assert_receive :expired
  end

  test "a meeting kept alive only by a hold is cancelled with the hold released" do
    ctx = host_and_session(status: :awaiting_payment)
    hold = open_hold(ctx, "late@example.com")
    stub(StripeAdapterMock, :expire_checkout_session, fn id, _opts -> {:ok, %{"id" => id}} end)

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert status(ctx.session) == :cancelled
    assert SeatHolds.get(hold.id).released_reason == :meeting_cancelled

    # Nobody paid, so the emails say nothing about refunds.
    assert [%{args: args}] =
             all_enqueued(worker: EmailWorker, args: %{action: "send_cancellation_emails"})

    refute Map.has_key?(args, "seat_refund")
  end

  test "a refund job failure does not undo the cancellation" do
    ctx = host_and_session()
    payment = paid_seat(ctx, "ada@example.com")

    # The work committed with the cancellation failing rolls it back.
    assert {:error, :boom} =
             Cancel.execute(ctx.session,
               caller: :organizer,
               announce: false,
               on_cancelled: fn _cancelled -> {:error, :boom} end
             )

    assert status(ctx.session) == :confirmed

    # A refund failing in its job leaves the session cancelled.
    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    expect(StripeAdapterMock, :create_refund, fn _params, _opts -> {:error, :api_error} end)
    assert [job] = all_enqueued(worker: GroupCancelRefund)
    assert {:error, :api_error} = perform_job(GroupCancelRefund, job.args)

    assert status(ctx.session) == :cancelled
    assert Repo.reload!(payment).refunded_amount_cents == 0
  end

  test "another host's seat payments are never refunded" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    other = insert(:user)
    paid_seat(ctx, "mallory@example.com", host_user_id: other.id)

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    assert [%{args: %{"host_user_id" => host_id}}] = all_enqueued(worker: GroupCancelRefund)
    assert host_id == ctx.host.id
    assert [_other_seat] = BookingPayments.seat_payments_for_meeting(ctx.session.id, other.id)
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

          Repo.delete_all(
            from(j in Oban.Job,
              where:
                fragment("?->>'meeting_id'", j.args) == ^ctx.session.id or
                  fragment("?->>'booking_payment_id'", j.args) in ^payment_ids
            )
          )

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
            from(j in Oban.Job,
              where: j.worker == ^inspect(GroupCancelRefund),
              select: fragment("?->>'booking_payment_id'", j.args)
            )
          )
        end)

      assert late_payment.id in refunded_ids
      assert length(refunded_ids) == 2
    end
  end
end
