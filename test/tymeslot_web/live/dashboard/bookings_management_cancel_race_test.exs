defmodule TymeslotWeb.Dashboard.BookingsManagementCancelRaceTest do
  @moduledoc """
  The host confirms the cancel modal after the attendee (or a calendar sync)
  has already cancelled the meeting: the modal still holds the meeting as it
  was when it opened.
  """

  use TymeslotWeb.LiveCase, async: true
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import Mox

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user)

    stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_organizer, fn _email, _details ->
      {:ok, nil}
    end)

    stub(Tymeslot.EmailServiceMock, :send_cancellation_email_to_attendee, fn _email, _details ->
      {:ok, nil}
    end)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Raced Guest"
      )

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user, meeting: meeting}
  end

  test "says it was already cancelled, closes the modal and refreshes the list",
       %{conn: conn, meeting: meeting} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("#cancel-meeting-#{meeting.id}") |> render_click()
    assert render(view) =~ "Are you sure you want to cancel"

    cancel_behind_the_modal(meeting)

    view |> form("#cancel-meeting-form") |> render_submit()

    html = render(view)
    assert html =~ "This booking was already cancelled."
    refute html =~ "Failed to cancel meeting"
    refute html =~ "Are you sure you want to cancel"
    assert html =~ "No upcoming meetings"
  end

  test "with a refund chosen, issues no refund and says none was issued",
       %{conn: conn, user: user, meeting: meeting} do
    payment =
      insert(:booking_payment,
        meeting_id: meeting.id,
        host_user_id: user.id,
        host_email: user.email,
        stripe_account_id: "acct_RACED",
        stripe_charge_id: "ch_RACED_#{System.unique_integer([:positive])}",
        amount_cents: 5000,
        application_fee_cents: 25,
        currency: "eur",
        status: "paid",
        paid_at: DateTime.utc_now(:second),
        refunded_amount_cents: 0
      )

    expect(StripeAdapterMock, :create_refund, 0, fn _params, _opts ->
      {:ok, %{id: "re_must_not_happen"}}
    end)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view |> element("#cancel-meeting-#{meeting.id}") |> render_click()

    cancel_behind_the_modal(meeting)

    view
    |> form("#cancel-meeting-form", %{"cancel_refund_choice" => "full"})
    |> render_submit()

    html = render(view)
    assert html =~ "This booking was already cancelled, so no refund was issued."
    refute html =~ "Are you sure you want to cancel"

    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.status == "paid"
    assert reloaded.refunded_amount_cents == 0
  end

  defp cancel_behind_the_modal(meeting) do
    meeting
    |> Changeset.change(status: "cancelled", cancelled_at: DateTime.utc_now(:second))
    |> Repo.update!()
  end
end
