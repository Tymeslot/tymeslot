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
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
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
        |> form("#calendar-search-form", %{"term" => "strategy"})
        |> render_change()

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
      |> form("#calendar-search-form", %{"term" => "strategy"})
      |> render_change()

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

    # A deselected calendar's rows stay cached until pruning runs, so search has
    # to honour the selection itself, as the grid does.
    test "omits matches from a calendar the user has deselected", %{conn: conn, user: user} do
      integration = caldav_integration_with_one_calendar_deselected(user)

      for {summary, path} <- [
            {"Strategy Workshop", "/cal/work/"},
            {"Strategy Book Club", "/cal/personal/"}
          ] do
        insert(:provider_calendar_event,
          calendar_integration: integration,
          summary: summary,
          start_at: ~U[2026-06-15 10:00:00Z],
          end_at: ~U[2026-06-15 11:00:00Z],
          provider_event_id: path <> "evt.ics"
        )
      end

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> form("#calendar-search-form", %{"term" => "strategy"})
        |> render_change()

      assert html =~ "Strategy Workshop"
      refute html =~ "Strategy Book Club"
    end

    test "a blank term keeps the results panel closed", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      html =
        lv
        |> form("#calendar-search-form", %{"term" => "   "})
        |> render_change()

      refute html =~ "calendar-search-results"
    end
  end

  defp caldav_integration_with_one_calendar_deselected(user) do
    insert(:calendar_integration,
      user: user,
      provider: "caldav",
      is_active: true,
      calendar_paths: ["/cal/work/"],
      calendar_list: [
        %{"id" => "/cal/work/", "path" => "/cal/work/", "selected" => true},
        %{"id" => "/cal/personal/", "path" => "/cal/personal/", "selected" => false}
      ]
    )
  end
end
