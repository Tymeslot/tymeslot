defmodule Tymeslot.MeetingPayments.Webhooks.SeatCheckoutExpiredTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.AccountCurrency
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionAsyncPaymentFailed
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionExpired
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.Seats
  alias Tymeslot.Repo
  alias Tymeslot.StripeWebhookFixtures

  @account "acct_SEAT_EXPIRY"

  setup do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 4, price_cents: 2500)

    start_time =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> then(&%{&1 | hour: 10, minute: 0, second: 0, microsecond: {0, 0}})

    %{user: user, meeting_type: meeting_type, start_time: start_time}
  end

  defp slot(ctx, attrs) do
    insert(
      :group_meeting,
      Keyword.merge(
        [
          organizer_user: ctx.user,
          meeting_type_ref: ctx.meeting_type,
          start_time: ctx.start_time,
          end_time: DateTime.add(ctx.start_time, 30, :minute),
          capacity: 4
        ],
        attrs
      )
    )
  end

  defp held_seat(ctx, meeting, hold_attrs) do
    hold = insert(:seat_hold, Keyword.merge([meeting: meeting], hold_attrs))

    payment =
      insert(:booking_payment,
        meeting: meeting,
        seat_hold_id: hold.id,
        seat_payment: true,
        seats: hold.seats,
        amount_cents: 2500 * hold.seats,
        host_user_id: ctx.user.id,
        stripe_account_id: @account,
        stripe_checkout_session_id: "cs_seat_#{hold.id}"
      )

    {hold, payment}
  end

  # A lapsed or failed session, in the shape the recorded fixture gives.
  defp session_event(type, event_id, payment) do
    "checkout.session.completed"
    |> StripeWebhookFixtures.event()
    |> Map.merge(%{"id" => event_id, "type" => type, "account" => @account})
    |> update_in(["data", "object"], fn session ->
      Map.merge(session, %{
        "id" => payment.stripe_checkout_session_id,
        "client_reference_id" => "seat_hold:" <> payment.seat_hold_id,
        "payment_status" => "unpaid",
        "status" => "expired",
        "metadata" => %{"seat_hold_id" => payment.seat_hold_id}
      })
    end)
  end

  defp expired_event(event_id, payment),
    do: session_event("checkout.session.expired", event_id, payment)

  test "an expired seat checkout releases the hold and the meeting it created", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com", seats: 2)
    account = insert(:connect_account, user: ctx.user, default_currency: "eur")
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))

    assert {:error, :pending_payments_exist} =
             AccountCurrency.change_default_currency(account, "usd")

    assert :ok = CheckoutSessionExpired.handle(expired_event("evt_lapsed", payment))

    assert %{status: :released, released_reason: :expired} = SeatHolds.get(hold.id)
    assert Repo.get!(MeetingSchema, meeting.id).status == :expired
    assert Seats.seats_occupied(meeting.id) == 0
    assert Repo.reload!(payment).status == :failed
    assert_receive :expired
    assert {:ok, _changed} = AccountCurrency.change_default_currency(account, "usd")
  end

  # The hold was deleted while the checkout was open (the booker's erasure,
  # say), and the group meeting it was held on still awaits other seats'
  # payments: only the payment fails.
  test "an expired seat checkout whose hold is gone fails the payment alone", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    event = expired_event("evt_hold_gone", payment)
    Repo.delete!(hold)

    assert :ok = CheckoutSessionExpired.handle(event)

    assert %{status: :failed, seat_hold_id: nil} = Repo.reload!(payment)
    assert Repo.get!(MeetingSchema, meeting.id).status == :awaiting_payment
  end

  # The booker waits on the hold's topic; the meeting's is for one-to-one
  # bookings, and a seat's lapse must not end anyone's wait there.
  test "a seat expiry never broadcasts on the meeting topic", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, Checkout.payment_topic(meeting.id))
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))

    assert :ok = CheckoutSessionExpired.handle(expired_event("evt_quiet_expiry", payment))

    assert Repo.get!(MeetingSchema, meeting.id).status == :expired
    assert_receive :expired
    refute_receive :expired
  end

  test "an expired hold on a joined meeting leaves the meeting", ctx do
    meeting = slot(ctx, status: :confirmed)
    insert(:participant, meeting: meeting, email: "seated@example.com")
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    assert :ok = CheckoutSessionExpired.handle(expired_event("evt_joined", payment))

    assert SeatHolds.get(hold.id).status == :released
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
    assert Seats.seats_occupied(meeting.id) == 1
  end

  test "the last hold lapsing on an emptied confirmed meeting cancels it", ctx do
    meeting = slot(ctx, status: :confirmed)
    {_hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    assert :ok = CheckoutSessionExpired.handle(expired_event("evt_emptied", payment))

    assert %{status: :cancelled, cancelled_at: %DateTime{}} =
             Repo.get!(MeetingSchema, meeting.id)
  end

  test "an abandoned hold keeps its reason", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    {:ok, _released} = SeatHolds.release(hold, :abandoned)

    assert :ok = CheckoutSessionExpired.handle(expired_event("evt_abandoned", payment))

    assert %{status: :released, released_reason: :abandoned} = SeatHolds.get(hold.id)
    assert Repo.reload!(payment).status == :failed
    assert Repo.get!(MeetingSchema, meeting.id).status == :expired
  end

  test "an async payment failure releases as failed", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    event = session_event("checkout.session.async_payment_failed", "evt_async", payment)
    assert :ok = CheckoutSessionAsyncPaymentFailed.handle(event)

    assert %{status: :released, released_reason: :failed} = SeatHolds.get(hold.id)
    assert Repo.reload!(payment).status == :failed
  end

  test "a hold released already is not announced a second time", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    {:ok, _released} = SeatHolds.release(hold, :abandoned)
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))

    assert :ok = CheckoutSessionExpired.handle(expired_event("evt_released_already", payment))

    assert Repo.reload!(payment).status == :failed
    refute_received :expired
  end

  test "a failed payment whose hold is still held releases it", ctx do
    meeting = slot(ctx, status: :awaiting_payment)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    payment |> Changeset.change(status: :failed) |> Repo.update!()
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))

    assert :ok = CheckoutSessionExpired.handle(expired_event("evt_failed_held", payment))

    assert %{status: :released, released_reason: :expired} = SeatHolds.get(hold.id)
    assert Repo.get!(MeetingSchema, meeting.id).status == :expired
    assert_received :expired
  end
end
