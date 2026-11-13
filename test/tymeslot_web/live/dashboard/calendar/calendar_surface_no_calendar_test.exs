defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceNoCalendarTest do
  @moduledoc """
  The calendar with no calendar connected: the rail says what still
  shows (bookings and bookable times) and offers to connect one; with a
  calendar connected it offers nothing.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup %{conn: conn} do
    context = owner(conn)
    TestMocks.stub_no_calendar_events()
    context
  end

  test "the rail says what still shows and offers to connect a calendar", %{
    conn: conn,
    integration: integration
  } do
    Repo.delete!(integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-rail-connect",
             "No calendar connected. Your bookings and bookable times still show here."
           )

    lv |> element("#calendar-connect", "Connect a calendar") |> render_click()
    assert_patch(lv, ~p"/dashboard/integrations?tab=calendars")
  end

  test "with a calendar connected the rail lists it and offers nothing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-rail", "Work account")
    refute has_element?(lv, "#calendar-rail-connect")
    refute has_element?(lv, "#calendar-connect")
  end

  test "settings say whether accounts exist when none has a writable calendar", %{
    conn: conn,
    user: user,
    integration: integration
  } do
    Repo.delete!(integration)

    insert(:calendar_integration,
      user: user,
      name: "Holidays",
      provider: "ics_url",
      is_active: true,
      calendar_list: [%{"id" => "feed", "name" => "Public holidays", "selected" => true}]
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{settings: %{calendars: [], has_accounts: true}})
    refute has_element?(lv, "#calendar-rail-connect")
  end

  test "settings say there are no accounts when none is connected", %{
    conn: conn,
    integration: integration
  } do
    Repo.delete!(integration)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{settings: %{calendars: [], has_accounts: false}})
  end
end
