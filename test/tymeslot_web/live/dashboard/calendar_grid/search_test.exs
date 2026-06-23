defmodule TymeslotWeb.Dashboard.CalendarGrid.SearchTest do
  @moduledoc """
  LiveView coverage for calendar event search. The user-level action is
  "type a term, see matching events, click one to jump there and open it".
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
    integration = insert(:calendar_integration, user: user, is_active: true)

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, integration: integration}
  end

  describe "event search" do
    test "typing a term renders matching events", %{conn: conn, integration: integration} do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Quarterly Strategy Review",
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z]
      )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> element("#calendar-search-input")
        |> render_keyup(%{"term" => "strategy"})

      assert html =~ "calendar-search-results"
      assert html =~ "Quarterly Strategy Review"
    end

    test "selecting a result navigates to its day and opens the detail modal", %{
      conn: conn,
      integration: integration
    } do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Quarterly Strategy Review",
        start_at: ~U[2026-06-15 10:00:00Z],
        end_at: ~U[2026-06-15 11:00:00Z]
      )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-search-input")
      |> render_keyup(%{"term" => "strategy"})

      html =
        lv
        |> element("#calendar-search-results button", "Quarterly Strategy Review")
        |> render_click()

      # Detail modal opened for the selected event.
      assert html =~ ~s(id="event-detail-modal")
      assert html =~ "Quarterly Strategy Review"
      # Navigated into day view, so the results panel is dismissed.
      refute html =~ "calendar-search-results"
    end

    test "a blank term keeps the results panel closed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> element("#calendar-search-input")
        |> render_keyup(%{"term" => "   "})

      refute html =~ "calendar-search-results"
    end
  end
end
