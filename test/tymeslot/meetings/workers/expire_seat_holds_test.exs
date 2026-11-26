defmodule Tymeslot.Meetings.Workers.ExpireSeatHoldsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.Workers.ExpireSeatHolds
  alias Tymeslot.Repo
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  @account "acct_SWEEP"

  setup :verify_on_exit!

  setup do
    # A slot rebuilt for a late payment asks for the type's calendar; these
    # hosts have none.
    Mox.stub(Tymeslot.CalendarMock, :get_booking_integration_info, fn _context ->
      {:error, :no_integration}
    end)

    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 4, price_cents: 2500)

    start_time =
      DateTime.utc_now()
      |> DateTime.add(5, :day)
      |> then(&%{&1 | hour: 10, minute: 0, second: 0, microsecond: {0, 0}})

    meeting =
      insert(:group_meeting,
        organizer_user: user,
        meeting_type_ref: meeting_type,
        title: meeting_type.name,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute),
        duration: 30,
        capacity: 4,
        status: :awaiting_payment
      )

    %{user: user, meeting: meeting}
  end

  defp overdue_hold(ctx, minutes_ago, payment_attrs) do
    hold =
      insert(:seat_hold,
        meeting: ctx.meeting,
        email: "payer@example.com",
        expires_at: DateTime.add(DateTime.utc_now(:second), -minutes_ago, :minute)
      )

    payment =
      payment_attrs &&
        insert(
          :booking_payment,
          Keyword.merge(
            [
              meeting: ctx.meeting,
              seat_hold_id: hold.id,
              seat_payment: true,
              seats: 1,
              amount_cents: 2500,
              host_user_id: ctx.user.id,
              stripe_account_id: @account
            ],
            payment_attrs
          )
        )

    {hold, payment}
  end

  defp stripe_reports(session) do
    StripeStub.expect(:retrieve_checkout_session, fn %{path: path, headers: headers} ->
      assert headers["stripe-account"] == @account
      session_id = path |> String.split("/") |> List.last()
      "checkout_session_payment" |> StripeFixtures.object(session) |> Map.put("id", session_id)
    end)
  end

  test "an overdue hold whose session expired is released", ctx do
    {hold, payment} = overdue_hold(ctx, 10, stripe_checkout_session_id: "cs_sweep_expired")
    stripe_reports(%{"status" => "expired", "payment_status" => "unpaid"})

    assert {:ok, %{reconciled: 1}} = perform_job(ExpireSeatHolds, %{})

    assert %{status: :released, released_reason: :expired} = SeatHolds.get(hold.id)
    assert Repo.reload!(payment).status == :failed
    assert Repo.get!(MeetingSchema, ctx.meeting.id).status == :expired
  end

  test "an overdue hold whose session was paid is converted", ctx do
    {hold, payment} = overdue_hold(ctx, 10, stripe_checkout_session_id: "cs_sweep_paid")

    stripe_reports(%{
      "status" => "complete",
      "payment_status" => "paid",
      "amount_total" => 2500,
      "currency" => payment.currency,
      "payment_intent" => "pi_sweep_paid"
    })

    assert {:ok, %{reconciled: 1}} = perform_job(ExpireSeatHolds, %{})

    assert SeatHolds.get(hold.id).status == :converted
    assert Repo.reload!(payment).status == :paid

    assert [%{email: "payer@example.com"}] =
             ParticipantQueries.list_live_for_meeting(ctx.meeting.id)
  end

  test "an overdue hold with no session is released as failed", ctx do
    {hold, payment} = overdue_hold(ctx, 10, stripe_checkout_session_id: nil)

    assert {:ok, %{released: 1}} = perform_job(ExpireSeatHolds, %{})

    assert %{status: :released, released_reason: :failed} = SeatHolds.get(hold.id)
    assert Repo.reload!(payment).status == :failed
    assert Repo.get!(MeetingSchema, ctx.meeting.id).status == :expired
  end

  test "an overdue hold with no payment at all is released as failed", ctx do
    {hold, nil} = overdue_hold(ctx, 10, nil)

    assert {:ok, %{released: 1}} = perform_job(ExpireSeatHolds, %{})
    assert %{status: :released, released_reason: :failed} = SeatHolds.get(hold.id)
  end

  test "a session Stripe still reports open is left for a later run", ctx do
    {hold, payment} = overdue_hold(ctx, 10, stripe_checkout_session_id: "cs_sweep_open")
    stripe_reports(%{"status" => "open", "payment_status" => "unpaid"})

    assert {:ok, %{skipped: 1}} = perform_job(ExpireSeatHolds, %{})
    assert SeatHolds.get(hold.id).status == :held
    assert Repo.reload!(payment).status == :pending
  end

  test "a session Stripe cannot be asked about is counted as an error and left held", ctx do
    {hold, payment} = overdue_hold(ctx, 10, stripe_checkout_session_id: "cs_sweep_unreadable")
    StripeStub.stub(:retrieve_checkout_session, {:error_fixture, "api_error"})

    capture_log(fn ->
      assert {:ok, %{errors: 1, released: 0, reconciled: 0}} = perform_job(ExpireSeatHolds, %{})
    end)

    assert SeatHolds.get(hold.id).status == :held
    assert Repo.reload!(payment).status == :pending
  end

  # An asynchronous payment method (a bank debit) completes the session
  # before the money arrives; the hold waits for the payment's own outcome.
  test "a completed session still awaiting its asynchronous payment is skipped", ctx do
    {hold, payment} = overdue_hold(ctx, 10, stripe_checkout_session_id: "cs_sweep_async")

    stripe_reports(%{
      "status" => "complete",
      "payment_status" => "unpaid",
      "amount_total" => 2500,
      "currency" => payment.currency
    })

    assert {:ok, %{skipped: 1, released: 0, reconciled: 0}} = perform_job(ExpireSeatHolds, %{})

    assert SeatHolds.get(hold.id).status == :held
    assert Repo.reload!(payment).status == :pending
    assert Repo.get!(MeetingSchema, ctx.meeting.id).status == :awaiting_payment
  end

  test "a hold inside its grace period is left alone", ctx do
    {hold, _payment} = overdue_hold(ctx, 2, stripe_checkout_session_id: "cs_sweep_grace")

    assert {:ok, %{released: 0, reconciled: 0, skipped: 0, errors: 0}} =
             perform_job(ExpireSeatHolds, %{})

    assert SeatHolds.get(hold.id).status == :held
  end

  test "a hold still held beside a paid payment is reported, never released", ctx do
    {hold, payment} =
      overdue_hold(ctx, 10, status: :paid, stripe_checkout_session_id: "cs_sweep_paid_held")

    Phoenix.PubSub.subscribe(Tymeslot.PubSub, SeatHolds.topic(hold.id))

    log =
      capture_log(fn ->
        assert {:ok, %{errors: 1, released: 0}} = perform_job(ExpireSeatHolds, %{})
      end)

    assert log =~ "still held beside a settled payment"
    assert SeatHolds.get(hold.id).status == :held
    assert Repo.reload!(payment).status == :paid
    assert Repo.get!(MeetingSchema, ctx.meeting.id).status == :awaiting_payment
    refute_received :expired
  end

  # The dispute reached the payment before its completion reached the
  # hold: Stripe took the money, so the session is replayed and the seat
  # booked, rather than the hold reported as broken.
  test "a hold whose payment was disputed before its completion is reconciled", ctx do
    {hold, payment} =
      overdue_hold(ctx, 10, status: :disputed, stripe_checkout_session_id: "cs_sweep_disputed")

    stripe_reports(%{
      "status" => "complete",
      "payment_status" => "paid",
      "amount_total" => 2500,
      "currency" => payment.currency,
      "payment_intent" => "pi_sweep_disputed"
    })

    assert {:ok, %{reconciled: 1, errors: 0}} = perform_job(ExpireSeatHolds, %{})

    assert SeatHolds.get(hold.id).status == :converted
    assert Repo.reload!(payment).status == :disputed

    assert [%{email: "payer@example.com"}] =
             ParticipantQueries.list_live_for_meeting(ctx.meeting.id)
  end

  test "a hold left open goes behind the holds a sweep has not looked at", ctx do
    long_ago = DateTime.add(DateTime.utc_now(:second), -3600, :second)
    {open, _payment} = overdue_hold(ctx, 20, stripe_checkout_session_id: "cs_sweep_still_open")
    open |> Changeset.change(updated_at: long_ago) |> Repo.update!()

    stripe_reports(%{"status" => "open", "payment_status" => "unpaid"})
    assert {:ok, %{skipped: 1}} = perform_job(ExpireSeatHolds, %{})

    # Less overdue than the open one, but not looked at yet.
    waiting =
      insert(:seat_hold,
        meeting: ctx.meeting,
        email: "waiting@example.com",
        expires_at: DateTime.add(DateTime.utc_now(:second), -10, :minute),
        updated_at: DateTime.add(long_ago, 60, :second)
      )

    assert [first, second] = SeatHolds.list_overdue(DateTime.utc_now(:second), 2)
    assert {first.id, second.id} == {waiting.id, open.id}
  end
end
