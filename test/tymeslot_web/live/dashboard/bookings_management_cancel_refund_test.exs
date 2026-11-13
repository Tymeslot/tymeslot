defmodule TymeslotWeb.Dashboard.BookingsManagementCancelRefundTest do
  @moduledoc """
  The paid-booking cancel dialog when a submit is refused: the choice, amount
  and acknowledgement are the host's until submit, so a re-render without them
  would snap the choice back to a full refund.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meetings
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  test "a refused partial amount stays a partial refund, with the amount beside the error",
       %{conn: conn, user: user} do
    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Paid Partial"
      )

    payment =
      insert(:booking_payment,
        meeting_id: meeting.id,
        host_user_id: user.id,
        host_email: user.email,
        stripe_account_id: "acct_PAID4",
        stripe_charge_id: "ch_PAID_#{System.unique_integer([:positive])}",
        amount_cents: 5000,
        application_fee_cents: 25,
        currency: "eur",
        status: :paid,
        paid_at: DateTime.utc_now(:second),
        refunded_amount_cents: 0
      )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

    view
    |> form("#cancel-meeting-form", %{
      "cancel_refund_choice" => "partial",
      "cancel_refund_amount" => "999.00"
    })
    |> render_submit()

    assert has_element?(view, "input[name=cancel_refund_choice][value=partial][checked]")
    refute has_element?(view, "input[name=cancel_refund_choice][value=full][checked]")
    assert has_element?(view, "input[name=cancel_refund_amount][value='999.00']")
    assert has_element?(view, "#cancel-meeting-form [role=alert]", "exceeds the remaining")
    refute has_element?(view, "#cancel-refund-ack-error")
    assert Repo.get(MeetingSchema, meeting.id).status == :confirmed
    assert BookingPaymentQueries.get(payment.id).refunded_amount_cents == 0
  end
end
