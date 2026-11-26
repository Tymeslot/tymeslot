defmodule Tymeslot.Bookings.CancelAwaitingPaymentTest do
  @moduledoc """
  Cancelling a paid booking whose Stripe Checkout is still open. Whoever
  cancels it, the cancellation schedules the checkout's expiry in its own
  transaction, so the attendee cannot pay for a booking that will not
  happen, and a Stripe outage is retried.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.Workers.ExpireCheckoutSession
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.TestMocks

  @account "acct_CANCEL_HOST"
  @session_id "cs_CANCEL_WHILE_OPEN"

  setup do
    TestMocks.setup_email_mocks()
    %{user: user} = create_user_with_profile()
    %{user: user}
  end

  test "the host's cancellation closes the open checkout", %{user: user} do
    {meeting, payment} = held_booking(user, :awaiting_payment)

    {:ok, refund_action} = Meetings.resolve_cancellation_refund(payment, %{})
    assert refund_action == {:not_refunded, :not_paid}

    assert {:ok, %{status: :cancelled}} =
             Meetings.cancel_meeting_with_refund(meeting, user.id, refund_action)

    assert [%{args: args}] = all_enqueued(worker: ExpireCheckoutSession)
    assert args == %{"meeting_id" => meeting.id}

    StripeStub.expect(
      :expire_checkout_session,
      StripeFixtures.object("checkout_session_expired", %{"id" => @session_id})
    )

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :payments)

    assert [%{path: "/v1/checkout/sessions/" <> @session_id <> "/expire", headers: headers}] =
             StripeStub.requests(:expire_checkout_session)

    assert headers["stripe-account"] == @account
  end

  test "the attendee's cancellation closes it too", %{user: user} do
    {meeting, _payment} = held_booking(user, :awaiting_payment)

    assert {:ok, %{status: :cancelled}} = Meetings.cancel_meeting(meeting)
    assert_enqueued(worker: ExpireCheckoutSession, args: %{meeting_id: meeting.id})
  end

  test "a booking already paid for has no checkout to close", %{user: user} do
    {meeting, _payment} = held_booking(user, :confirmed)

    assert {:ok, %{status: :cancelled}} =
             Meetings.cancel_meeting_with_refund(meeting, user.id, :none)

    refute_enqueued(worker: ExpireCheckoutSession)
  end

  # The job commits with the cancellation or not at all: a booking left
  # cancelled with nothing closing its checkout could still be paid for.
  test "a cancellation whose expiry cannot be scheduled is not made", %{user: user} do
    {meeting, _payment} = held_booking(user, :awaiting_payment)

    :meck.new(Oban, [:passthrough])
    :meck.expect(Oban, :insert, fn _job -> {:error, :queue_not_available} end)

    try do
      assert {:error, :queue_not_available} = Meetings.cancel_meeting(meeting)
    after
      :meck.unload(Oban)
    end

    assert {:ok, %{status: :awaiting_payment}} = MeetingQueries.get_meeting(meeting.id)
  end

  defp held_booking(user, status) do
    meeting =
      insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3600, status: status})

    payment_status = if status == :awaiting_payment, do: :pending, else: :paid

    insert(:booking_payment,
      meeting: meeting,
      host_user_id: user.id,
      status: payment_status,
      paid_at: if(payment_status == :paid, do: DateTime.utc_now(:second)),
      stripe_account_id: @account,
      stripe_checkout_session_id: @session_id
    )

    {meeting, BookingPayments.payment_for_meeting(meeting.id, user.id)}
  end
end
