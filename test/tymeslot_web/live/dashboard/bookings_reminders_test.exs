defmodule TymeslotWeb.Dashboard.BookingsRemindersTest do
  @moduledoc """
  What a booking's card says about its reminders: which ones it carries, which
  have gone out, and the bookings that have none to show.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meetings
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  describe "reminders on a booking" do
    test "lists what the booking reminds with, and which have gone out", %{
      conn: conn,
      user: user
    } do
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        reminders: [%{"value" => 2, "unit" => "hours"}, %{"value" => 20, "unit" => "minutes"}],
        reminders_sent: [
          %{
            "value" => 2,
            "unit" => "hours",
            "organizer_sent" => true,
            "attendee_sent" => true
          }
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
      html = render(view)

      assert html =~ "2 hours before"
      assert html =~ "20 minutes before"
      assert html =~ "Sent"
      assert html =~ "Not yet sent"
    end

    test "a booking that asked for none shows no reminder section", %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        reminders: []
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      refute render(view) =~ "minutes before"
    end

    test "a row from before the column existed shows the reminder it still gets", %{
      conn: conn,
      user: user
    } do
      # `nil` is not "none": `Orchestrator` falls back to 30 minutes for such a
      # booking, so the list says what the guest will actually receive.
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        reminders: nil
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      assert render(view) =~ "30 minutes before"
    end

    test "a cancelled booking lists none: its reminder jobs went with it", %{
      conn: conn,
      user: user
    } do
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        status: "cancelled",
        reminders: [%{"value" => 20, "unit" => "minutes"}]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("button", "Cancelled") |> render_click()
      html = render(view)

      assert html =~ "Ada Lovelace"
      refute html =~ "20 minutes before"
    end

    test "a request still held for approval promises nothing yet", %{conn: conn, user: user} do
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        attendee_name: "Ada Lovelace",
        status: "awaiting_approval",
        reminders: [%{"value" => 20, "unit" => "minutes"}]
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

      view |> element("button", "Requests") |> render_click()
      html = render(view)

      assert html =~ "20 minutes before"
      assert html =~ "After approval"
    end
  end
end
