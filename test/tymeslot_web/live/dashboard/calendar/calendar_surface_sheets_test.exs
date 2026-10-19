defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSheetsTest do
  @moduledoc """
  The server-rendered sheets of the new calendar: the Calendars sheet (the
  rail's calendars and layers, and the display options, where the rail is
  hidden) and the date sheet (a month to pick a day from, opened from the
  phone header's title).
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  defp phone(conn), do: put_connect_params(conn, %{"viewport" => "phone"})

  defp open_calendars(lv), do: lv |> element("#calendar-phone-calendars") |> render_click()

  describe "the Calendars sheet" do
    setup %{conn: conn} do
      context = owner(conn)
      Map.put(context, :conn, phone(context.conn))
    end

    test "opens from the phone header with the calendars, layers and display options",
         %{conn: conn, user: user, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      refute has_element?(lv, "#calendar-calendars-sheet")

      # Opening the calendar syncs the account, which hides Sync now; let it end.
      send(lv.pid, {:calendar_sync_failed, user.id, integration.id})
      render(lv)
      render(lv)

      open_calendars(lv)

      sheet = "#calendar-calendars-sheet"
      assert has_element?(lv, "#calendar-phone-calendars[aria-expanded='true']")
      assert has_element?(lv, "#{sheet} [role='dialog']")
      assert has_element?(lv, "#{sheet} #calendar-sheet-account-#{integration.id}")
      assert has_element?(lv, "#{sheet} [data-calendar-id='work'][aria-checked='true']")
      assert has_element?(lv, "#{sheet} [data-calendar-id='family'][aria-checked='true']")
      assert has_element?(lv, "#{sheet} #calendar-sheet-sync-#{integration.id}")
      assert has_element?(lv, "#{sheet} #calendar-sheet-layers")
      assert has_element?(lv, "#{sheet} #calendar-sheet-density-comfortable[aria-pressed='true']")
      assert has_element?(lv, "#{sheet} #calendar-sheet-fold-night[role='switch']")
      assert has_element?(lv, "#{sheet} #calendar-sheet-back-to-old")
    end

    test "a calendar hidden there leaves the grid at once and the sheet stays open",
         %{conn: conn, integration: integration} do
      event(integration, "family", "Swimming", ~U[2026-10-14 16:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_calendars(lv)

      lv |> element("#calendar-calendars-sheet [data-calendar-id='family']") |> render_click()

      assert_push_event(lv, "calendar:events", %{reset: true, events: events})
      refute Enum.any?(events, &(&1.title == "Swimming"))

      assert has_element?(
               lv,
               "#calendar-calendars-sheet [data-calendar-id='family'][aria-checked='false']"
             )
    end

    test "while calendars are hidden, the first row offers to show them all", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#calendar-rail [data-calendar-id='family']") |> render_click()
      open_calendars(lv)

      assert has_element?(
               lv,
               "#calendar-calendars-sheet .cal-sheet-list > #calendar-sheet-hidden:first-child",
               "1 calendar hidden"
             )

      lv |> element("#calendar-sheet-show-all") |> render_click()

      refute has_element?(lv, "#calendar-sheet-show-all")

      assert has_element?(
               lv,
               "#calendar-calendars-sheet [data-calendar-id='family'][aria-checked='true']"
             )
    end

    test "nothing hidden, no Show all row", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_calendars(lv)

      refute has_element?(lv, "#calendar-sheet-hidden")
    end

    test "density chosen there is saved and sent to the canvas", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_calendars(lv)

      lv |> element("#calendar-sheet-density-compact") |> render_click()

      assert_push_event(lv, "calendar:settings", %{density: "compact"})
      assert CalendarPreferencesQueries.get_or_create(user.id).density == "compact"
    end

    test "the bookable switch there hides the layer", %{conn: conn, user: user} do
      insert(:meeting_type, user: user, name: "Intro call", sort_order: 0)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_calendars(lv)

      lv |> element("#calendar-sheet-bookable") |> render_click()

      refute CalendarPreferencesQueries.get_or_create(user.id).bookable_layer
      assert has_element?(lv, "#calendar-sheet-bookable[aria-checked='false']")
    end

    test "the close button closes it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_calendars(lv)

      lv |> element("#calendar-calendars-sheet [aria-label='Close modal']") |> render_click()

      refute has_element?(lv, "#calendar-calendars-sheet")
      assert has_element?(lv, "#calendar-phone-calendars[aria-expanded='false']")
    end
  end

  test "between 640 and 767px the toolbar's Calendars button opens the same sheet",
       %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(
             lv,
             "#calendar-calendars-button[class~='hidden'][class~='sm:inline-flex'][class~='md:hidden']"
           )

    lv |> element("#calendar-calendars-button") |> render_click()

    assert has_element?(lv, "#calendar-calendars-sheet [data-calendar-id='work']")
  end

  test "the rail keeps its own ids beside the sheet's", %{conn: conn} do
    %{conn: conn, integration: integration} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_calendars(lv)

    assert has_element?(lv, "#calendar-rail #calendar-account-#{integration.id}")
    assert has_element?(lv, "#calendar-rail #calendar-rail-layers")
    assert has_element?(lv, "#calendar-calendars-sheet #calendar-sheet-account-#{integration.id}")
    refute has_element?(lv, "#calendar-calendars-sheet #calendar-account-#{integration.id}")
  end
end
