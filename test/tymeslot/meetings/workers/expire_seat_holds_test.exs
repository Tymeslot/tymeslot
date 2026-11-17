defmodule Tymeslot.Meetings.Workers.ExpireSeatHoldsTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.SeatHolds
  alias Tymeslot.Meetings.Workers.ExpireSeatHolds
  alias Tymeslot.Repo

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
    expect(StripeAdapterMock, :retrieve_checkout_session, fn session_id, opts ->
      assert opts[:connect_account] == @account
      {:ok, Map.put(session, "id", session_id)}
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

  test "a hold inside its grace period is left alone", ctx do
    {hold, _payment} = overdue_hold(ctx, 2, stripe_checkout_session_id: "cs_sweep_grace")

    assert {:ok, %{released: 0, reconciled: 0, skipped: 0, errors: 0}} =
             perform_job(ExpireSeatHolds, %{})

    assert SeatHolds.get(hold.id).status == :held
  end
end
