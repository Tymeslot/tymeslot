defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceFocusTest do
  @moduledoc """
  Focus mode on the new calendar: the toolbar control, the display options
  switch and F (`calendar:toggle_focus`) hide the dashboard menu and the
  strips above the grid; the choice is saved and on the first paint; and it
  applies only to the new calendar, only while no product tour runs.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Repo

  # The tour points at the dashboard menu, so focus mode waits for it to end.
  defp organiser(conn, opts \\ []) do
    %{user: user} = context = owner(conn, opts)

    user
    |> Changeset.change(dashboard_tour_seen_at: DateTime.utc_now(:second))
    |> Repo.update!()

    context
  end

  # The agenda behind the Up next strip reads the real clock.
  defp upcoming_booking(user) do
    start_time = DateTime.add(DateTime.utc_now(), 3600, :second)

    insert(:meeting,
      organizer_user: user,
      organizer_email: user.email,
      title: "Strategy sync",
      attendee_name: "Grace Hopper",
      start_time: start_time,
      end_time: DateTime.add(start_time, 1800, :second),
      status: "confirmed"
    )
  end

  test "the toolbar control hides the dashboard menu, remembers it and tells the canvas", %{
    conn: conn
  } do
    %{conn: conn, user: user} = organiser(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, "#dashboard-root[data-calendar-focus]")

    assert has_element?(
             lv,
             "#calendar-focus-toggle[aria-pressed='false'][aria-label='Focus mode']"
           )

    lv |> element("#calendar-focus-toggle") |> render_click()

    assert has_element?(lv, "#dashboard-root[data-calendar-focus='true']")

    assert has_element?(
             lv,
             "#calendar-focus-toggle[aria-pressed='true'][aria-label='Leave focus mode']"
           )

    assert CalendarPreferencesQueries.get_or_create(user.id).focus_mode
    assert_push_event(lv, "calendar:settings", %{focus: true})

    lv |> element("#calendar-focus-toggle") |> render_click()

    refute has_element?(lv, "#dashboard-root[data-calendar-focus]")
    refute CalendarPreferencesQueries.get_or_create(user.id).focus_mode
    assert_push_event(lv, "calendar:settings", %{focus: false})
  end

  test "the display options switch and the event F pushes toggle it too", %{conn: conn} do
    %{conn: conn} = organiser(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-display-options > button") |> render_click()
    assert has_element?(lv, "#calendar-focus[aria-checked='false']")

    lv |> element("#calendar-focus") |> render_click()
    assert has_element?(lv, "#dashboard-root[data-calendar-focus='true']")

    # What F sends from the canvas hook: a push to the LiveView, no target.
    render_hook(lv, "calendar:toggle_focus", %{})
    refute has_element?(lv, "#dashboard-root[data-calendar-focus]")
  end

  test "a stored choice is on the first paint and reaches the canvas", %{conn: conn} do
    %{conn: conn} = organiser(conn, preferences: [focus_mode: true])

    html = conn |> get(~p"/dashboard/calendar") |> html_response(200)
    assert html =~ ~s(data-calendar-focus="true")

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})
    assert_reply(lv, %{settings: %{focus: true}})
  end

  test "focus mode leaves out the Up next and onboarding strips", %{conn: conn} do
    %{conn: conn, user: user} = organiser(conn, preferences: [focus_mode: true])
    upcoming_booking(user)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, "[data-testid='up-next-strip']")
    refute has_element?(lv, "[data-testid='onboarding-checklist']")

    lv |> element("#calendar-focus-toggle") |> render_click()

    assert has_element?(lv, "[data-testid='up-next-strip']", "Strategy sync")
    assert has_element?(lv, "[data-testid='onboarding-checklist']")
  end

  test "the old calendar ignores a stored focus mode until the organiser switches", %{
    conn: conn
  } do
    %{conn: conn} = organiser(conn, redesign_enabled: false, preferences: [focus_mode: true])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    refute has_element?(lv, "#dashboard-root[data-calendar-focus]")
    refute has_element?(lv, "#calendar-focus-toggle")

    render_hook(lv, "calendar:switch_surface", %{"enabled" => true})

    assert has_element?(lv, "#dashboard-root[data-calendar-focus='true']")
  end

  test "other dashboard pages keep the menu; the calendar takes focus mode back", %{
    conn: conn
  } do
    %{conn: conn} = organiser(conn, preferences: [focus_mode: true])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/overview")

    refute has_element?(lv, "#dashboard-root[data-calendar-focus]")
    assert has_element?(lv, "#dashboard-sidebar")

    render_patch(lv, ~p"/dashboard/calendar")
    assert has_element?(lv, "#dashboard-root[data-calendar-focus='true']")

    render_patch(lv, ~p"/dashboard/overview")
    refute has_element?(lv, "#dashboard-root[data-calendar-focus]")
  end

  test "a running tour suspends focus mode until it ends", %{conn: conn} do
    %{conn: conn} = owner(conn, preferences: [focus_mode: true])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#dashboard-tour")
    refute has_element?(lv, "#dashboard-root[data-calendar-focus]")

    render_hook(lv, "tour:skip", %{})

    assert has_element?(lv, "#dashboard-root[data-calendar-focus='true']")
  end

  test "the focus controls show from the lg breakpoint only", %{conn: conn} do
    %{conn: conn} = organiser(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert lv |> element("#calendar-focus-toggle") |> render() =~ "hidden lg:inline-flex"

    lv |> element("#calendar-display-options > button") |> render_click()
    assert has_element?(lv, "#calendar-focus-row.hidden")
  end
end
