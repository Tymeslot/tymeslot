defmodule Tymeslot.Meetings.CancellationGroupTest do
  @moduledoc """
  The host cancelling a paid group session: every paid seat refunded in
  full through one recorded refund each (source `:cancellation`), or none
  with the acknowledgement, and every seat still held for a booker paying released
  with its checkout expired.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [from: 2]

  @moduletag :payments
  @moduletag :bookings
  @moduletag :integration

  import Tymeslot.Factory
  import Tymeslot.GroupCancellationTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.StripeWebhookFixtures
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  @account Tymeslot.GroupCancellationTestHelpers.account()
  @price Tymeslot.GroupCancellationTestHelpers.price_cents()

  setup do
    TestMocks.setup_calendar_mocks()

    Mox.stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :none}
    end)

    :ok
  end

  # The refunds the host's cancellation recorded, by amount.
  defp cancellation_refunds do
    Repo.all(from(r in RefundSchema, where: r.source == :cancellation, order_by: r.amount_cents))
  end

  defp refund_amounts, do: Enum.map(cancellation_refunds(), & &1.amount_cents)

  defp expired_session(id),
    do: StripeFixtures.object("checkout_session_expired", %{"id" => id})

  defp status(meeting), do: Repo.get!(MeetingSchema, meeting.id).status

  defp seat_refund_arg do
    assert [%{args: args}] =
             all_enqueued(worker: EmailWorker, args: %{action: "send_cancellation_emails"})

    args["seat_refund"]
  end

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

  test "cancelling a paid group meeting records one refund per paid seat" do
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

    assert seat_refund_arg() == %{
             "choice" => "full",
             "count" => 3,
             "totals" => [%{"currency" => "eur", "amount_cents" => 5500}],
             "outside_window" => %{"count" => 0, "totals" => []}
           }
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

  test "no refund cancels without recording a refund" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert status(ctx.session) == :cancelled
    assert refund_amounts() == []

    assert seat_refund_arg() == %{
             "choice" => "none",
             "count" => 1,
             "totals" => [%{"currency" => "eur", "amount_cents" => @price}],
             "outside_window" => %{"count" => 0, "totals" => []}
           }
  end

  # A host who changed their currency between bookings holds money in both.
  test "seats paid in two currencies are totalled per currency" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com", currency: "usd", amount_cents: 3000)
    paid_seat(ctx, "grace@example.com")
    paid_seat(ctx, "alan@example.com", currency: "usd", amount_cents: 1000)

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert seat_refund_arg() == %{
             "choice" => "none",
             "count" => 3,
             "totals" => [
               %{"currency" => "eur", "amount_cents" => @price},
               %{"currency" => "usd", "amount_cents" => 4000}
             ],
             "outside_window" => %{"count" => 0, "totals" => []}
           }
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

    StripeStub.expect(:expire_checkout_session, expired_session(session_id))

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert %{status: :released, released_reason: :meeting_cancelled} = SeatHolds.get(hold.id)
    assert_receive :expired

    assert [%{path: path, headers: headers}] = StripeStub.requests(:expire_checkout_session)
    assert path =~ session_id
    assert headers["stripe-account"] == @account
  end

  test "a meeting kept alive only by a hold is cancelled with the hold released" do
    ctx = host_and_session(status: :awaiting_payment)
    hold = open_hold(ctx, "late@example.com")
    StripeStub.stub(:expire_checkout_session, StripeFixtures.object("checkout_session_expired"))

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :none)

    assert status(ctx.session) == :cancelled
    assert SeatHolds.get(hold.id).released_reason == :meeting_cancelled

    # Nobody paid, so the emails say nothing about refunds.
    assert [%{args: args}] =
             all_enqueued(worker: EmailWorker, args: %{action: "send_cancellation_emails"})

    refute Map.has_key?(args, "seat_refund")
  end

  test "a failing settlement rolls the cancellation back" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    hold = open_hold(ctx, "late@example.com")

    # The seats are settled as the host's cancellation settles them, then
    # the callback fails: nothing of it may commit.
    settle = fn cancelled ->
      SeatHolds.release_open_for_meeting(cancelled.id, :meeting_cancelled)

      {:ok, _refund} =
        cancelled.id
        |> BookingPayments.seat_payments_for_meeting(ctx.host.id)
        |> hd()
        |> MeetingPayments.request_refund(@price, :cancellation, host_user_id: ctx.host.id)

      {:error, :boom}
    end

    assert {:error, :boom} =
             Cancel.execute_settling(ctx.session, settle, caller: :organizer, announce: false)

    assert status(ctx.session) == :confirmed
    assert SeatHolds.get(hold.id).status == :held
    assert refund_amounts() == []
  end

  test "a refund Stripe declines does not undo the cancellation" do
    ctx = host_and_session()
    payment = paid_seat(ctx, "ada@example.com")

    # A refund failing in its job leaves the session cancelled.
    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    StripeStub.stub(:create_refund, {:error_fixture, "invalid_request_error"})
    assert [refund] = cancellation_refunds()
    assert_enqueued(worker: ExecuteRefund, args: %{refund_id: refund.id})
    perform_job(ExecuteRefund, %{refund_id: refund.id})

    assert status(ctx.session) == :cancelled
    assert Repo.reload!(payment).refunded_amount_cents == 0
    assert [%{status: :failed}] = RefundQueries.list_for_payment(payment.id)
  end

  test "another host's seat payments are never refunded" do
    ctx = host_and_session()
    paid_seat(ctx, "ada@example.com")
    other = insert(:user)
    paid_seat(ctx, "mallory@example.com", host_user_id: other.id)

    assert {:ok, _cancelled} =
             Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

    assert [%{requested_by_user_id: host_id}] = cancellation_refunds()
    assert host_id == ctx.host.id
    assert [_other_seat] = BookingPayments.seat_payments_for_meeting(ctx.session.id, other.id)
  end

  test "a payment that never became a seat is neither refunded nor counted" do
    ctx = host_and_session()

    refused =
      insert(:seat_hold, meeting: ctx.session, status: :released, released_reason: :failed)

    # Refused at checkout for a full slot: its own refund is already
    # recorded (`:late_payment`), and it never had a participant.
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

  # The host chose against the seats the dialog showed; a seat paid after
  # that (converted between the dialog's last check and the cancellation's
  # own read under the meeting's lock) must not be refunded, or kept,
  # without the host seeing it.
  describe "the seats the host chose against" do
    test "a seat paid since rolls the cancellation back, returning the seats now" do
      ctx = host_and_session()
      seen = paid_seat(ctx, "ada@example.com")
      late = paid_seat(ctx, "late@example.com")

      assert {:error, {:payments_changed, payments}} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats,
                 seat_payment_ids: [seen.id]
               )

      assert payments |> Enum.map(& &1.id) |> Enum.sort() == Enum.sort([seen.id, late.id])
      assert status(ctx.session) == :confirmed
      assert refund_amounts() == []
      refute_enqueued(worker: EmailWorker, args: %{action: "send_cancellation_emails"})
    end

    test "the seats the host saw are settled" do
      ctx = host_and_session()
      seen = paid_seat(ctx, "ada@example.com")

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats,
                 seat_payment_ids: [seen.id]
               )

      assert status(ctx.session) == :cancelled
      assert refund_amounts() == [@price]
    end
  end

  describe "the refund action" do
    test "any action on a group meeting settles it seat by seat" do
      ctx = host_and_session()
      paid_seat(ctx, "ada@example.com")
      hold = open_hold(ctx, "late@example.com")
      StripeStub.stub(:expire_checkout_session, StripeFixtures.object("checkout_session_expired"))

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

      StripeStub.expect(:expire_checkout_session, expired_session(session_id))

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
      StripeStub.stub(:retrieve_payment_intent, fn %{path: path} ->
        intent = path |> String.split("/") |> List.last()
        StripeStubResponses.payment_intent(intent, "ch_" <> intent)
      end)

      StripeStub.stub(:expire_checkout_session, {:error_fixture, "invalid_request_error"})

      :ok
    end

    test "is refunded exactly once, by its own late refund" do
      ctx = host_and_session()
      hold = open_hold(ctx, "late@example.com")
      payment = BookingPayments.payment_for_seat_hold(hold.id)

      assert {:ok, _cancelled} =
               Meetings.cancel_meeting_with_refund(ctx.session, ctx.host.id, :refund_seats)

      assert :ok = CheckoutSessionCompleted.handle(completed_event(payment))

      assert [%{source: :late_payment, amount_cents: @price}] =
               RefundQueries.list_for_payment(payment.id)

      assert refund_amounts() == []

      StripeStub.expect(:create_refund, &StripeStubResponses.refund(&1, "re_LATE_SEAT"))

      assert %{failure: 0} = Oban.drain_queue(queue: :payments, with_scheduled: true)

      assert %{status: :refunded, refunded_amount_cents: @price} = Repo.reload!(payment)
    end
  end
end
