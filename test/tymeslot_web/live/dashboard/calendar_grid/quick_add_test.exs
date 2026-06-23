defmodule TymeslotWeb.Dashboard.CalendarGrid.QuickAddTest do
  @moduledoc """
  LiveView coverage for the calendar quick-add input. Submitting natural-language
  text must parse on the server and open the create modal pre-filled — the
  user-level action is "type a line, get a ready-to-confirm draft".
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    insert(:calendar_integration, user: user, is_active: true)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "quick-add" do
    test "submitting a timed line opens the create modal pre-filled", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> form("#calendar-grid-header form[phx-submit=quick_add]", %{text: "Lunch 1pm for 90m"})
        |> render_submit()

      assert html =~ "New Event"
      assert html =~ ~s(id="create-event-modal")
      # Title carried over from the parsed text.
      assert html =~ ~s(value="Lunch")
      # Default user timezone is UTC, so 1pm → 13:00 start, 14:30 end.
      assert html =~ ~s(value="13:00")
      assert html =~ ~s(value="14:30")
    end

    test "submitting freeform text opens the modal with just the title", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> form("#calendar-grid-header form[phx-submit=quick_add]", %{text: "Some freeform note"})
        |> render_submit()

      assert html =~ "New Event"
      assert html =~ ~s(value="Some freeform note")
    end

    test "submitting blank text does not open the modal", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> form("#calendar-grid-header form[phx-submit=quick_add]", %{text: "   "})
        |> render_submit()

      refute html =~ ~s(id="create-event-modal")
    end
  end
end
