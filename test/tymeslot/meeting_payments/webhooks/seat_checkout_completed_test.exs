defmodule Tymeslot.MeetingPayments.Webhooks.SeatCheckoutCompletedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import ExUnit.CaptureLog
  import Tymeslot.Factory
  import Tymeslot.StripeConnectTestHelpers, only: [enable_meeting_payments: 1]

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.RefundSchema
  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Repo
  alias Tymeslot.StripeWebhookFixtures
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.Test.EnqueuedJobs
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.WebhookWorker

  @account "acct_SEAT_HOST"
  @seat_price 2500

  setup :enable_meeting_payments

  setup do
    # A slot rebuilt for a late payment asks for the type's calendar; these
    # hosts have none.
    Mox.stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    user = insert(:user)
    _profile = insert(:profile, user: user)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Group Class",
        max_participants: 4,
        payment_required: true,
        price_cents: @seat_price
      )

    # A late payment takes a new meeting only on a type taking payments now.
    insert(:connect_account,
      user: user,
      stripe_account_id: @account,
      default_currency: "eur",
      charges_enabled: true
    )

    start_time =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> then(&%{&1 | hour: 10, minute: 0, second: 0, microsecond: {0, 0}})

    %{user: user, meeting_type: meeting_type, start_time: start_time}
  end

  defp slot(ctx, attrs \\ []) do
    insert(
      :group_meeting,
      Keyword.merge(
        [
          organizer_user: ctx.user,
          meeting_type_ref: ctx.meeting_type,
          title: ctx.meeting_type.name,
          start_time: ctx.start_time,
          end_time: DateTime.add(ctx.start_time, 30, :minute),
          duration: 30,
          capacity: 4,
          status: :awaiting_payment
        ],
        attrs
      )
    )
  end

  defp held_seat(ctx, meeting, hold_attrs, payment_attrs \\ []) do
    hold = insert(:seat_hold, Keyword.merge([meeting: meeting], hold_attrs))

    payment =
      insert(
        :booking_payment,
        Keyword.merge(
          [
            meeting: meeting,
            seat_hold_id: hold.id,
            seat_payment: true,
            seats: hold.seats,
            amount_cents: @seat_price * hold.seats,
            host_user_id: ctx.user.id,
            stripe_account_id: @account,
            stripe_checkout_session_id: "cs_seat_#{hold.id}"
          ],
          payment_attrs
        )
      )

    {hold, payment}
  end

  # The shape Stripe delivers, from the recorded fixture, for this seat.
  defp completed_event(event_id, payment, object \\ %{}) do
    "checkout.session.completed"
    |> StripeWebhookFixtures.event()
    |> Map.merge(%{"id" => event_id, "account" => @account})
    |> update_in(["data", "object"], fn session ->
      Map.merge(
        session,
        Map.merge(
          %{
            "id" => payment.stripe_checkout_session_id,
            "client_reference_id" => "seat_hold:" <> payment.seat_hold_id,
            "payment_intent" => "pi_#{payment.seat_hold_id}",
            "payment_status" => "paid",
            "amount_total" => payment.amount_cents,
            "currency" => payment.currency,
            "metadata" => %{"seat_hold_id" => payment.seat_hold_id}
          },
          object
        )
      )
    end)
  end

  defp seat_confirmations(user, participant_id) do
    user
    |> EnqueuedJobs.for_user()
    |> Enum.filter(
      &(&1.worker == inspect(EmailWorker) and
          &1.args["action"] == "send_seat_confirmation_emails" and
          &1.args["participant_id"] == participant_id)
    )
  end

  defp calendar_creates(user, meeting_id) do
    user
    |> EnqueuedJobs.for_user()
    |> Enum.filter(
      &(&1.worker == inspect(CalendarEventWorker) and &1.args["action"] == "create" and
          &1.args["meeting_id"] == meeting_id)
    )
  end

  # The refund a refused seat's completion recorded (`:late_payment`).
  defp refunds_for(payment),
    do:
      payment.id |> RefundQueries.list_for_payment() |> Enum.filter(&(&1.source == :late_payment))

  defp lapsed_seat(ctx, meeting, email) do
    held_seat(
      ctx,
      meeting,
      [email: email, status: :released, released_reason: :expired],
      status: :failed
    )
  end

  test "a paid seat becomes a participant and is announced", ctx do
    meeting = slot(ctx)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_seat_paid", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert participant.email == "payer@example.com"
    assert paid.participant_id == participant.id
    assert paid.meeting_id == meeting.id
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed

    participant_id = participant.id
    assert_receive {:paid, ^participant_id}
    assert [_one] = seat_confirmations(ctx.user, participant.id)
  end

  test "converting a hold fires one seat-booked automation", ctx do
    insert(:webhook, user: ctx.user, events: ["meeting.created"])
    meeting = slot(ctx)
    {_hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_automation", payment))

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)

    assert [job] = all_enqueued(worker: WebhookWorker)
    assert job.args["event_type"] == "meeting.created"
    assert job.args["meeting_id"] == meeting.id
    assert job.args["participant_id"] == participant.id
  end

  test "the first paid seat schedules the calendar event, the second does not", ctx do
    meeting = slot(ctx)
    {_first_hold, first} = held_seat(ctx, meeting, email: "first@example.com")
    {_second_hold, second} = held_seat(ctx, meeting, email: "second@example.com")

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_first", first))
    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_second", second))

    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
    assert [_one] = calendar_creates(ctx.user, meeting.id)

    assert_enqueued(
      worker: CalendarEventWorker,
      args: %{"action" => "update", "meeting_id" => meeting.id}
    )
  end

  test "a replay of the same event is idempotent", ctx do
    meeting = slot(ctx)
    {_hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    event = completed_event("evt_replayed", payment)

    assert :ok = CheckoutSessionCompleted.handle(event)
    assert :ok = CheckoutSessionCompleted.handle(event)

    assert [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert [_one] = seat_confirmations(ctx.user, participant.id)
  end

  test "a second event for a paid seat is a no-op", ctx do
    meeting = slot(ctx)
    {_hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_one", payment))
    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_two", payment))

    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
    assert Repo.reload!(payment).last_event_id == "evt_one"
    refute Repo.exists?(RefundSchema)
  end

  test "a late payment with room books the seat", ctx do
    meeting = slot(ctx, status: :expired)

    {hold, payment} =
      held_seat(
        ctx,
        meeting,
        [email: "late@example.com", status: :released, released_reason: :expired],
        status: :failed
      )

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_late", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert paid.meeting_id != meeting.id
    assert %MeetingSchema{status: :confirmed} = Repo.get!(MeetingSchema, paid.meeting_id)
    assert [%{id: participant_id}] = ParticipantQueries.list_live_for_meeting(paid.meeting_id)
    assert paid.participant_id == participant_id
    assert SeatHolds.get(hold.id).status == :converted
    refute Repo.exists?(RefundSchema)
  end

  test "a late payment without room is refunded", ctx do
    lapsed = slot(ctx, status: :expired)
    full = slot(ctx, status: :confirmed, capacity: 2)
    insert(:participant, meeting: full, email: "one@example.com")
    insert(:participant, meeting: full, email: "two@example.com")

    {hold, payment} =
      held_seat(
        ctx,
        lapsed,
        [email: "late@example.com", status: :released, released_reason: :expired],
        status: :failed
      )

    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_late_full", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert paid.participant_id == nil
    assert [_one] = refunds_for(paid)
    assert_receive :expired
    assert length(ParticipantQueries.list_live_for_meeting(full.id)) == 2
  end

  test "a payment for a seat on a cancelled meeting is refunded", ctx do
    meeting = slot(ctx, status: :cancelled)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_cancelled", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert [_one] = refunds_for(paid)
    assert %{status: :released, released_reason: :failed} = SeatHolds.get(hold.id)
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end

  # The hold is deleted (on the booker's erasure, say) while the checkout is
  # open: the seat payment is refunded, and the group meeting other seats
  # share is never confirmed by it.
  test "a payment whose hold is gone is refunded and confirms nothing", ctx do
    meeting = slot(ctx)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    event = completed_event("evt_hold_gone", payment)
    Repo.delete!(hold)

    assert :ok = CheckoutSessionCompleted.handle(event)

    paid = Repo.reload!(payment)
    assert %{status: :paid, seat_hold_id: nil} = paid
    assert [_one] = refunds_for(paid)
    assert Repo.reload!(meeting).status == :awaiting_payment
    assert calendar_creates(ctx.user, meeting.id) == []
  end

  test "a seat session is found by its reference when its id was never attached", ctx do
    meeting = slot(ctx)

    {_hold, payment} =
      held_seat(ctx, meeting, [email: "payer@example.com"], stripe_checkout_session_id: nil)

    event = completed_event("evt_by_reference", payment, %{"id" => "cs_never_attached"})

    assert :ok = CheckoutSessionCompleted.handle(event)
    assert Repo.reload!(payment).status == :paid
    assert [_participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
  end

  test "an amount that does not match the seats is skipped", ctx do
    meeting = slot(ctx)
    {_hold, payment} = held_seat(ctx, meeting, email: "payer@example.com", seats: 1)

    event = completed_event("evt_short", payment, %{"amount_total" => @seat_price - 1})

    assert :ok = CheckoutSessionCompleted.handle(event)
    assert Repo.reload!(payment).status == :pending
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end

  test "a seat payment never broadcasts on the meeting topic", ctx do
    meeting = slot(ctx)
    {_hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, Checkout.payment_topic(meeting.id))

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_quiet", payment))

    assert Repo.reload!(payment).status == :paid
    refute_receive :paid
  end

  # The hold-only group meeting is outside the confirmed-slot unique index
  # until its first paid seat confirms it, and the organiser's confirmed
  # one-to-one at the same start collides with it then. Postgres aborts the
  # whole webhook transaction, so the refund is recorded in a fresh one.
  test "a seat whose slot collides with a confirmed meeting is refunded, not left pending",
       ctx do
    insert(:meeting,
      organizer_user: ctx.user,
      start_time: ctx.start_time,
      end_time: DateTime.add(ctx.start_time, 30, :minute),
      status: :confirmed
    )

    meeting = slot(ctx)
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    event = completed_event("evt_collision", payment)
    assert :ok = CheckoutSessionCompleted.handle(event)

    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert paid.last_event_id == "evt_collision"
    assert %{status: :released, released_reason: :failed} = SeatHolds.get(hold.id)
    assert Repo.get!(MeetingSchema, meeting.id).status == :expired
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []

    assert :ok = CheckoutSessionCompleted.handle(event)
    assert [_one] = refunds_for(paid)
  end

  test "a host pending deletion takes no paid seat", ctx do
    meeting = slot(ctx)
    {_hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    ctx.user
    |> Changeset.change(deletion_scheduled_at: DateTime.add(DateTime.utc_now(:second), 7, :day))
    |> Repo.update!()

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_leaving", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert [_one] = refunds_for(paid)
    assert ParticipantQueries.list_live_for_meeting(meeting.id) == []
  end

  # The registration check runs twice: once before anything is written,
  # and again on the locked row as the seat is taken. A session closing
  # between the two (staged by moving the clock past the close as the hold
  # is marked converted) rolls the conversion back, so the refund must run
  # in a fresh transaction rather than inside the aborted one.
  test "a registration closing mid-conversion refunds the seat in a fresh transaction", ctx do
    closes_at = DateTime.add(ctx.start_time, -1, :day)
    session = slot(ctx, status: :confirmed, planned: true, registration_closes_at: closes_at)
    {hold, payment} = lapsed_seat(ctx, session, "late@example.com")

    ClockHelpers.freeze_clock(DateTime.add(closes_at, -60, :second))
    close_registration_on_conversion(DateTime.add(closes_at, 60, :second))

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_closing", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert paid.participant_id == nil
    assert [_one] = refunds_for(paid)
    assert %{status: :released, released_reason: :expired} = SeatHolds.get(hold.id)
    assert ParticipantQueries.list_live_for_meeting(session.id) == []
  end

  defp close_registration_on_conversion(later) do
    test_pid = self()
    handler_id = "close-registration-#{inspect(make_ref())}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:tymeslot, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid and metadata[:source] == "seat_holds" and
               metadata[:query] =~ ~r/^UPDATE .*"status" = /,
             do: ClockHelpers.freeze_clock(later)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "a hold held on a session whose registration closed since is still booked", ctx do
    session =
      slot(ctx,
        status: :confirmed,
        planned: true,
        registration_closes_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)
      )

    {hold, payment} = held_seat(ctx, session, email: "early@example.com")

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_reserved", payment))

    assert Repo.reload!(payment).status == :paid
    assert [%{email: "early@example.com"}] = ParticipantQueries.list_live_for_meeting(session.id)
    assert SeatHolds.get(hold.id).status == :converted
    assert refunds_for(payment) == []
  end

  test "a lapsed hold on a session whose registration closed is refunded", ctx do
    session =
      slot(ctx,
        status: :confirmed,
        planned: true,
        registration_closes_at: DateTime.add(DateTime.utc_now(:second), -3600, :second)
      )

    {_hold, payment} = lapsed_seat(ctx, session, "late@example.com")

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_closed", payment))

    assert Repo.reload!(payment).status == :paid
    assert [_one] = refunds_for(payment)
    assert ParticipantQueries.list_live_for_meeting(session.id) == []
  end

  test "a seat captured already disputed is booked and stays disputed", ctx do
    meeting = slot(ctx)
    {hold, payment} = held_seat(ctx, meeting, [email: "payer@example.com"], status: :disputed)

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_disputed", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :disputed
    assert %DateTime{} = paid.paid_at
    assert [%{id: participant_id}] = ParticipantQueries.list_live_for_meeting(meeting.id)
    assert paid.participant_id == participant_id
    assert SeatHolds.get(hold.id).status == :converted
    assert refunds_for(paid) == []

    # Stripe redelivering the completion after the dispute books nothing twice.
    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_disputed_again", payment))
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
  end

  test "a disputed seat refused for a full slot releases the hold, its refund left to the dispute",
       ctx do
    meeting = slot(ctx, status: :confirmed, capacity: 2)
    insert(:participant, meeting: meeting, email: "one@example.com")
    insert(:participant, meeting: meeting, email: "two@example.com")
    {hold, payment} = held_seat(ctx, meeting, [email: "payer@example.com"], status: :disputed)

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_disputed_full", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :disputed
    assert %{status: :released, released_reason: :failed} = SeatHolds.get(hold.id)
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 2
    assert [%{status: :failed, failure_code: "under_dispute"}] = refunds_for(paid)
  end

  # The booker's email has a free seat on the meeting already, which only
  # the insert finds, having written: the conversion rolls back.
  test "a seat whose email is already booked on the meeting is refunded", ctx do
    meeting = slot(ctx, status: :confirmed)
    insert(:participant, meeting: meeting, email: "payer@example.com")
    {hold, payment} = held_seat(ctx, meeting, email: "payer@example.com")

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_twice", payment))

    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert [_one] = refunds_for(paid)
    assert %{status: :released, released_reason: :failed} = SeatHolds.get(hold.id)
    assert length(ParticipantQueries.list_live_for_meeting(meeting.id)) == 1
  end

  test "a seat whose conversion can never succeed is refunded rather than retried", ctx do
    meeting = slot(ctx, status: :confirmed)
    insert(:participant, meeting: meeting, email: "seated@example.com")
    # The factory skips the hold's changeset, so the participant's refuses it.
    {hold, payment} = held_seat(ctx, meeting, email: "not-an-email")

    log =
      capture_log(fn ->
        assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_invalid", payment))
      end)

    assert log =~ "seat conversion failed for good"
    paid = Repo.reload!(payment)
    assert paid.status == :paid
    assert [_one] = refunds_for(paid)
    assert %{status: :released, released_reason: :failed} = SeatHolds.get(hold.id)
  end

  test "a lapsed hold on a fixed-date type is refunded, not booked on a new session", ctx do
    fixed_type =
      insert(:meeting_type,
        user: ctx.user,
        max_participants: 4,
        fixed_dates: true,
        payment_required: true,
        price_cents: @seat_price
      )

    lapsed = slot(ctx, status: :expired, meeting_type_ref: fixed_type)
    {_hold, payment} = lapsed_seat(ctx, lapsed, "late@example.com")

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_fixed", payment))

    assert Repo.reload!(payment).status == :paid
    assert [_one] = refunds_for(payment)
    assert Repo.aggregate(MeetingSchema, :count) == 1
  end

  test "a lapsed hold whose type was deleted is refunded", ctx do
    lapsed = slot(ctx, status: :expired)
    {_hold, payment} = lapsed_seat(ctx, lapsed, "late@example.com")
    Repo.delete!(ctx.meeting_type)

    assert :ok = CheckoutSessionCompleted.handle(completed_event("evt_deleted", payment))

    assert Repo.reload!(payment).status == :paid
    assert [_one] = refunds_for(payment)
    assert Repo.aggregate(MeetingSchema, :count) == 1
  end
end
