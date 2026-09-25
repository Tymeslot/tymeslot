defmodule TymeslotWeb.Dashboard.CalendarGrid.DesktopRemindersLiveViewTest do
  @moduledoc """
  LiveView coverage for the desktop-reminder feed the calendar page hands to the
  browser. The user-level action is "keep the calendar open and get a desktop
  notification before each event I can see".
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    {:ok, _prefs} = CalendarPreferencesQueries.upsert(user.id, %{desktop_reminders_enabled: true})

    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    {:ok, conn: log_in_user(conn, user), user: user}
  end

  # A deselected calendar's rows stay cached until pruning runs, so the feed has
  # to honour the selection itself, as the grid does.
  test "omits events from a calendar the user has deselected", %{conn: conn, user: user} do
    integration =
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

    start_at = DateTime.add(DateTime.utc_now(), 2, :day)

    for {summary, path} <- [{"Work Meeting", "/cal/work/"}, {"Personal Errand", "/cal/personal/"}] do
      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: summary,
        start_at: start_at,
        end_at: DateTime.add(start_at, 1, :hour),
        all_day: false,
        provider_event_id: path <> "evt.ics",
        reminders: [%{"method" => "popup", "minutes_before" => 10}]
      )
    end

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    feed = lv |> element("#desktop-reminders") |> render()

    assert feed =~ "Work Meeting"
    refute feed =~ "Personal Errand"
  end
end
