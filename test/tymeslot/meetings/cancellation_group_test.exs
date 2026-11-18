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
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.GroupCancelRefund
  alias Tymeslot.MeetingPayments.Workers.RefundLatePayment
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.GroupScheduling
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Repo
  alias Tymeslot.StripeWebhookFixtures
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

  # The shape Stripe delivers, from the recorded fixture, for this seat.
  defp completed_event(payment) do
    "checkout.session.completed"
    |> StripeWebhookFixtures.event()
    |> Map.merge(%{"id" => "evt_after_cancel", "account" => @account})
    |> update_in(["data", "object"], fn session ->
      Map.merge(session, %{
        "id" => payment.stripe_checkout_session_id,
        "client_reference_id" => "seat_hold:" <> payment.seat_hold_id,
        "payment_intent" => "pi_#{payment.seat_hold_id}",
        "payment_status" => "paid",
        "amount_total" => payment.amount_cents,
        "currency" => payment.currency,
        "metadata" => %{"seat_hold_id" => payment.seat_hold_id}
      })
    end)
  end

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

  test "a failing on_cancelled rolls the cancellation back" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    hold = open_hold(ctx, "late@example.com")

    # The seats are settled as the host's cancellation settles them, then
    # the callback fails: nothing of it may commit.
    on_cancelled = fn cancelled ->
      SeatHolds.release_open_for_meeting(cancelled.id, :meeting_cancelled)

      Oban.insert!(
        GroupCancelRefund.new_for(
          hd(BookingPayments.seat_payments_for_meeting(cancelled.id, ctx.host.id)),
          ctx.host.id,
          @price
        )
      )

      {:error, :boom}
    end

    assert {:error, :boom} =
             Cancel.execute(ctx.session,
               caller: :organizer,
               announce: false,
               on_cancelled: on_cancelled
             )

    assert status(ctx.session) == :confirmed
    assert SeatHolds.get(hold.id).status == :held
    assert refund_amounts() == []
  end

  test "a refund job failure does not undo the cancellation" do
    ctx = host_and_session()
    payment = paid_seat(ctx, "ada@example.com")

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

  test "a payment that never became a seat is neither refunded nor counted" do
    ctx = host_and_session()

    refused =
      insert(:seat_hold, meeting: ctx.session, status: :released, released_reason: :failed)

    # Refused at checkout for a full slot: its own refund is already queued
    # (`RefundLatePayment`), and it never had a participant.
    insert(:paid_booking_payment,
      meeting_id: ctx.session.id,
      seat_hold_id: refused.id,
      seat_payment: true,
      amount_cents: @price,
      host_user_id: ctx.host.id,
      stripe_account_id: @account
    )

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    assert refund_amounts() == []

    # Nobody holds a paid seat, so the emails say nothing about refunds.
    assert [%{args: args}] =
             all_enqueued(worker: EmailWorker, args: %{action: "send_cancellation_emails"})

    refute Map.has_key?(args, "seat_refund")
  end

  test "a participant who left before the host cancelled is not refunded" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    left = paid_seat(ctx, "grace@example.com", amount_cents: 1500)

    left.participant_id
    |> then(&Repo.get!(ParticipantSchema, &1))
    |> Changeset.change(cancelled_at: DateTime.utc_now(:second))
    |> Repo.update!()

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    assert refund_amounts() == [2000]
  end

  describe "the refund action" do
    test "any action on a group meeting settles it seat by seat" do
      ctx = host_and_session()
      paid_seat(ctx, "ada@example.com")
      hold = open_hold(ctx, "late@example.com")
      stub(StripeAdapterMock, :expire_checkout_session, fn id, _opts -> {:ok, %{"id" => id}} end)

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(
                 ctx.session,
                 ctx.host.id,
                 {:not_refunded, :outside_refund_window}
               )

      assert SeatHolds.get(hold.id).released_reason == :meeting_cancelled
      assert refund_amounts() == []
    end

    test "an amount on a group meeting refunds every seat in full" do
      ctx = host_and_session()
      paid_seat(ctx, "ada@example.com")

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, {:refund, 500})

      assert refund_amounts() == [2000]
    end

    test "refund_seats on a one-to-one meeting is refused with nothing cancelled" do
      host = insert(:user)
      meeting = insert(:meeting, organizer_user_id: host.id, status: :confirmed)

      assert {:error, :not_found} =
               Meetings.cancel_meeting_with_refund(meeting, host.id, :refund_seats)

      assert status(meeting) == :confirmed
    end
  end

  describe "the host deleting the session from their calendar" do
    test "releases the open holds and refunds no seat, as for a one-to-one meeting" do
      ctx = host_and_session()
      paid_seat(ctx, "ada@example.com")
      hold = open_hold(ctx, "late@example.com")
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))
      session_id = "cs_open_#{hold.id}"

      expect(StripeAdapterMock, :expire_checkout_session, fn ^session_id, _opts ->
        {:ok, %{"id" => session_id, "status" => "expired"}}
      end)

      assert {:ok, cancelled} = Cancel.execute_external(ctx.session)

      assert cancelled.status == :cancelled
      assert %{status: :released, released_reason: :meeting_cancelled} = SeatHolds.get(hold.id)
      assert_receive :expired
      assert refund_amounts() == []
    end
  end

  describe "a checkout completing after the host cancelled" do
    setup do
      # The completed webhook backfills the charge the refund is made on.
      stub(StripeAdapterMock, :retrieve_payment_intent, fn intent, _opts ->
        {:ok, %{"latest_charge" => "ch_" <> intent}}
      end)

      stub(StripeAdapterMock, :expire_checkout_session, fn _id, _opts ->
        {:error, :already_completed}
      end)

      :ok
    end

    test "is refunded exactly once, by its own late refund" do
      ctx = host_and_session()
      hold = open_hold(ctx, "late@example.com")
      payment = BookingPayments.payment_for_seat_hold(hold.id)

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

      assert :ok = CheckoutSessionCompleted.handle(completed_event(payment))

      assert [_one] =
               all_enqueued(
                 worker: RefundLatePayment,
                 args: %{"booking_payment_id" => payment.id}
               )

      assert refund_amounts() == []

      expect(StripeAdapterMock, :create_refund, 1, fn %{amount: @price}, _opts ->
        {:ok, %{"id" => "re_LATE_SEAT"}}
      end)

      assert %{failure: 0} = Oban.drain_queue(queue: :payments)

      assert %{status: :refunded, refunded_amount_cents: @price} = Repo.reload!(payment)
    end
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
