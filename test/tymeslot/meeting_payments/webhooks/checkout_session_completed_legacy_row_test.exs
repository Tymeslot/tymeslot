defmodule Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompletedLegacyRowTest do
  @moduledoc """
  `checkout.session.completed` for a booking whose other details no longer
  pass the full meeting validation: a solo meeting with no attendee name, as
  older rows can carry. The completion writes only the status and its
  approval fields, so it confirms such a booking (or moves it into the
  approval gate) instead of failing validation, rolling back and being
  retried for good while the money sits taken.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :integration

  @account "acct_TEST_HOST"
  @paid_session %{"payment_status" => "paid", "amount_total" => 5000, "currency" => "eur"}

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.Webhooks.CheckoutSessionCompleted
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Repo

  test "confirms the meeting" do
    meeting = legacy_meeting(status: "awaiting_payment")
    bp = insert_payment(meeting, "LEGACY")

    assert :ok = CheckoutSessionCompleted.handle(completed_event(meeting, "LEGACY"))

    assert Repo.reload!(bp).status == "paid"
    assert {:ok, %{status: "confirmed"}} = MeetingQueries.get_meeting(meeting.id)
  end

  test "moves a gated meeting into the approval gate, its clock restarted" do
    requested_at = DateTime.add(DateTime.utc_now(:second), -1, :hour)

    meeting =
      legacy_meeting(
        status: "awaiting_payment",
        approval_requested_at: requested_at,
        approval_deadline_at: DateTime.add(requested_at, 12, :hour)
      )

    insert_payment(meeting, "LEGACY_GATED")

    assert :ok = CheckoutSessionCompleted.handle(completed_event(meeting, "LEGACY_GATED"))

    {:ok, gated} = MeetingQueries.get_meeting(meeting.id)
    assert gated.status == "awaiting_approval"
    assert DateTime.after?(gated.approval_requested_at, requested_at)
  end

  defp legacy_meeting(attrs) do
    meeting = insert(:meeting, attrs)
    Repo.update_all(from(m in Meeting, where: m.id == ^meeting.id), set: [attendee_name: nil])
    meeting
  end

  defp insert_payment(meeting, suffix) do
    insert(:booking_payment,
      stripe_account_id: @account,
      meeting: meeting,
      status: "pending",
      stripe_checkout_session_id: "cs_#{suffix}"
    )
  end

  defp completed_event(meeting, suffix) do
    %{
      "id" => "evt_#{suffix}",
      "account" => @account,
      "type" => "checkout.session.completed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" =>
          Map.merge(@paid_session, %{
            "id" => "cs_#{suffix}",
            "client_reference_id" => meeting.id,
            "payment_intent" => "pi_#{suffix}"
          })
      }
    }
  end
end
