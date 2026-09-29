defmodule Tymeslot.Meetings.ApprovalErrorTrackingTest do
  @moduledoc """
  Releasing a paid booking request refunds it after the release has
  committed, so a refund that fails cannot undo the release. It is recorded
  in ErrorTracker instead, as is any post-release step that raises.
  """

  # async: false: ErrorTracker's `enabled` switch is global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :payments

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Meetings.Approval

  setup :verify_on_exit!

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  defp paid_held_meeting do
    user = insert(:user)

    meeting =
      insert(:meeting,
        status: "awaiting_approval",
        organizer_user: user,
        organizer_user_id: user.id,
        approval_requested_at: DateTime.utc_now(:second),
        approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
      )

    insert(:booking_payment, %{
      meeting_id: meeting.id,
      stripe_charge_id: "ch_TEST_#{System.unique_integer([:positive])}",
      stripe_account_id: "acct_TEST",
      amount_cents: 5000,
      refunded_amount_cents: 0,
      application_fee_cents: 0,
      status: "paid",
      paid_at: DateTime.utc_now(:second)
    })

    meeting
  end

  defp recorded_errors, do: Error |> Repo.all() |> Repo.preload(:occurrences)

  test "a refund Stripe refuses is recorded with the meeting and payment" do
    meeting = paid_held_meeting()
    payment = BookingPaymentQueries.by_meeting_id(meeting.id)

    expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
      {:error, :outside_refund_window}
    end)

    capture_log(fn -> assert {:ok, _expired} = Approval.expire(meeting) end)

    assert [%Error{kind: "Elixir.Tymeslot.Infrastructure.ErrorTracking.HandledError"} = error] =
             recorded_errors()

    assert [%{context: context}] = error.occurrences
    assert context["meeting_id"] == meeting.id
    assert context["payment_id"] == payment.id
    assert context["amount_cents"] == 5000
  end

  test "a post-release step that raises is recorded with the step and meeting" do
    meeting = paid_held_meeting()

    expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
      raise "stripe client bug"
    end)

    capture_log(fn -> assert {:ok, _expired} = Approval.expire(meeting) end)

    assert [%Error{kind: "Elixir.RuntimeError", reason: "stripe client bug"} = error] =
             recorded_errors()

    assert [%{context: %{"step" => "refund unapproved request", "meeting_id" => id}}] =
             error.occurrences

    assert id == meeting.id
  end
end
