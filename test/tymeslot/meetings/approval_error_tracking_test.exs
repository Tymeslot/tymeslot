defmodule Tymeslot.Meetings.ApprovalErrorTrackingTest do
  @moduledoc """
  Releasing a paid booking request records its refund after the release
  has committed, so a refund refused cannot undo the release. It is
  recorded in ErrorTracker instead, as is any post-release step that raises.
  """

  # async: false: ErrorTracker's `enabled` switch is global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :meetings
  @moduletag :payments

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.ConfigTestHelpers

  alias Ecto.Changeset
  alias ErrorTracker.Error
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.CommittedStep
  alias Tymeslot.StripeStub

  setup :verify_on_exit!

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  defp paid_held_meeting do
    user = insert(:user)

    meeting =
      insert(:meeting,
        status: :awaiting_approval,
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
      status: :paid,
      paid_at: DateTime.utc_now(:second)
    })

    meeting
  end

  defp recorded_errors, do: Error |> Repo.all() |> Repo.preload(:occurrences)

  test "a refund the payment no longer allows is recorded with the meeting and payment" do
    meeting = paid_held_meeting()
    payment = BookingPaymentQueries.by_meeting_id(meeting.id)

    payment
    |> Changeset.change(paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day))
    |> Repo.update!()

    capture_log(fn -> assert {:ok, _expired} = Approval.expire(meeting) end)

    assert [%Error{kind: "Elixir.Tymeslot.Infrastructure.ErrorTracking.HandledError"} = error] =
             recorded_errors()

    assert error.reason =~ "outside_refund_window"
    assert [%{context: context}] = error.occurrences
    assert context["meeting_id"] == meeting.id
    assert context["payment_id"] == payment.id
    assert context["amount_cents"] == 5000
    assert StripeStub.requests() == []
  end

  # The release's refund step asks nothing of Stripe, so the raise is the
  # step's own: what every post-release step runs through.
  test "a post-release step that raises is recorded with the step and meeting" do
    meeting = paid_held_meeting()

    capture_log(fn ->
      CommittedStep.run(meeting, "refund unapproved request", fn -> raise "refund step bug" end)
    end)

    assert [%Error{kind: "Elixir.RuntimeError", reason: "refund step bug"} = error] =
             recorded_errors()

    assert [%{context: %{"step" => "refund unapproved request", "meeting_id" => id}}] =
             error.occurrences

    assert id == meeting.id
  end
end
