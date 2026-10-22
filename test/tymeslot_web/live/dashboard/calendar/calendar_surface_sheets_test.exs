defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSheetsTest do
  @moduledoc """
  The server-rendered sheets of the calendar: the Calendars sheet (the
  rail's calendars and layers, and the display options, where the rail is
  hidden) and the date sheet (a month to pick a day from, opened from the
  phone header's title). It also pins what the server renders for the hook's
  sheets: the scrim behind the event preview, and the side panel's header that
  the full-screen editor pads and enlarges (placement itself is CSS and
  `calendar/sheet.js`, tested under `assets/js/__tests__/calendar/`).
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory, only: [insert: 2]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Repo

  defp phone(conn), do: put_connect_params(conn, %{"viewport" => "phone"})

  defp open_calendars(lv), do: lv |> element("#calendar-phone-calendars") |> render_click()
  defp open_dates(lv), do: lv |> element("#calendar-phone-title") |> render_click()

  defp canvas_hook(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  describe "the Calendars sheet" do
    setup %{conn: conn} do
      context = owner(conn)
      Map.put(context, :conn, phone(context.conn))
    end

    test "opens from the phone header with the calendars, layers and display options",
         %{conn: conn, user: user, integration: integration} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      refute has_element?(lv, "#calendar-calendars-sheet")

      # Opening the calendar syncs the account, which hides Sync now; the
      # sheet shows that state too, then let it end.
      open_calendars(lv)
      assert has_element?(lv, "#calendar-calendars-sheet [data-syncing]")
      send(lv.pid, {:calendar_sync_failed, user.id, integration.id})
      render(lv)
      render(lv)

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
    end

    test "names its calendars section with a visible heading, as it does sets and layers",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_calendars(lv)

      sheet = "#calendar-calendars-sheet"

      heading =
        "#{sheet} section[aria-labelledby='calendar-sheet-heading'] > h2#calendar-sheet-heading"

      assert has_element?(lv, heading, "Calendars")
      refute has_element?(lv, "#{heading}.sr-only")
      assert has_element?(lv, "#{sheet} h2#calendar-sheet-sets-heading", "Calendar sets")
      assert has_element?(lv, "#{sheet} h2#calendar-sheet-layers-heading", "Layers")
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

  test "with no calendar connected the sheet offers to connect one", %{conn: conn} do
    %{conn: conn, integration: integration} = owner(conn)
    Repo.delete!(integration)
    {:ok, lv, _html} = live(phone(conn), ~p"/dashboard/calendar")
    open_calendars(lv)

    assert has_element?(lv, "#calendar-calendars-sheet #calendar-sheet-connect-link")
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

  describe "the date sheet" do
    setup %{conn: conn} do
      context = owner(conn)
      Map.put(context, :conn, phone(context.conn))
    end

    test "the header's period opens a month of 44px days", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(
               lv,
               "button#calendar-phone-title[aria-haspopup='dialog']",
               "14 – 16 Oct"
             )

      assert has_element?(lv, "#calendar-phone-title[aria-label='Choose a date, 14 to 16 Oct']")

      open_dates(lv)

      assert has_element?(lv, "#calendar-phone-title[aria-expanded='true']")
      assert has_element?(lv, "#calendar-date-sheet #calendar-sheet-month", "October 2026")
      assert has_element?(lv, "#calendar-sheet-month button[aria-pressed='true'][class~='h-11']")
      assert has_element?(lv, "#calendar-date-sheet #calendar-sheet-today", "Today")
      assert has_element?(lv, "#calendar-rail-month button[class~='h-7']")
    end

    test "the sheet's arrows are 44px, the rail's are not", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_dates(lv)

      assert has_element?(
               lv,
               "#calendar-sheet-month button[aria-label='Next month'][class~='h-11']"
             )

      assert has_element?(
               lv,
               "#calendar-sheet-month button[aria-label='Previous month'][class~='w-11']"
             )

      refute has_element?(
               lv,
               "#calendar-rail-month button[aria-label='Next month'][class~='h-11']"
             )
    end

    test "the month bleeds into the body's padding on a phone and is named", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_dates(lv)

      assert has_element?(lv, "#calendar-date-sheet div[class~='-mx-10'] #calendar-sheet-month")
      assert has_element?(lv, "#calendar-sheet-month-label[aria-live='polite']", "October 2026")

      assert has_element?(
               lv,
               "#calendar-sheet-month [role='group'][aria-labelledby='calendar-sheet-month-label']"
             )
    end

    # The global `.grid` rule adds a 16px gap, which left each day 36px wide
    # at 360px; the days fill their column instead.
    test "the month's rows have no gap, so each day spans its column", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_dates(lv)

      assert has_element?(lv, "#calendar-sheet-month [role='group'] > div[class~='gap-0']")
      refute has_element?(lv, "#calendar-sheet-month [role='group'] > div:not([class~='gap-0'])")
      assert has_element?(lv, "#calendar-sheet-month div[aria-hidden='true'][class~='gap-0']")
    end

    test "reopening shows the period's month, not the month last paged to", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_dates(lv)
      lv |> element("#calendar-sheet-month button[aria-label='Next month']") |> render_click()
      assert has_element?(lv, "#calendar-sheet-month", "November 2026")

      open_dates(lv)
      refute has_element?(lv, "#calendar-date-sheet")
      open_dates(lv)

      assert has_element?(lv, "#calendar-sheet-month", "October 2026")
    end

    test "a day goes there in the current view and closes the sheet", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_dates(lv)

      lv |> element("#calendar-sheet-month button", ~r/^\s*20\s*$/) |> render_click()

      assert_patch(lv, ~p"/dashboard/calendar?view=three_day&date=2026-10-20")
      refute has_element?(lv, "#calendar-date-sheet")
    end

    test "Today goes back to today and closes the sheet", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar?view=three_day&date=2026-10-30")
      open_dates(lv)

      lv |> element("#calendar-sheet-today") |> render_click()

      assert_patch(lv, ~p"/dashboard/calendar?view=three_day&date=2026-10-14")
      refute has_element?(lv, "#calendar-date-sheet")
    end

    test "Today with today shown only closes the sheet", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_dates(lv)

      lv |> element("#calendar-sheet-today") |> render_click()

      refute has_element?(lv, "#calendar-date-sheet")
      refute_patched(lv)
    end

    test "the arrows page the sheet's month", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_dates(lv)

      lv |> element("#calendar-sheet-month button[aria-label='Next month']") |> render_click()

      assert has_element?(lv, "#calendar-sheet-month", "November 2026")
    end
  end

  describe "the toolbar's date picker" do
    setup %{conn: conn}, do: owner(conn)

    test "reopening shows the period's month, not the month last paged to", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      toggle = fn ->
        lv |> element("#calendar-date-picker [phx-value-menu='date']") |> render_click()
      end

      toggle.()
      lv |> element("#calendar-picker-month button[aria-label='Next month']") |> render_click()
      assert has_element?(lv, "#calendar-picker-month", "November 2026")

      toggle.()
      toggle.()

      assert has_element?(lv, "#calendar-picker-month", "October 2026")
    end
  end

  describe "the preview and the panel" do
    setup %{conn: conn} do
      context = owner(conn)
      review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
      {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

      Map.merge(context, %{lv: lv, id: "event-#{review.id}"})
    end

    test "the preview comes with a scrim just before it, and both go when it closes", %{
      lv: lv,
      id: id
    } do
      refute has_element?(lv, ".cal-scrim")

      canvas_hook(lv, "calendar:open", %{"id" => id})
      assert has_element?(lv, ".cal-scrim[aria-hidden='true'] + #calendar-preview")

      canvas_hook(lv, "calendar:close_preview", %{"refocus" => "false"})
      refute has_element?(lv, ".cal-scrim")
      refute has_element?(lv, "#calendar-preview")
    end

    test "the panel's header, which the full-screen editor pads and enlarges, holds its close button",
         %{lv: lv, id: id} do
      canvas_hook(lv, "calendar:edit", %{"id" => id})

      assert has_element?(lv, "#calendar-panel > .cal-panel-head #calendar-panel-close")
    end
  end
end
