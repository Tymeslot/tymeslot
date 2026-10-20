defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceDisplayTest do
  @moduledoc """
  The calendar's display options, drawn once (`DisplayOptions`) for the
  toolbar and the Calendars sheet: density, the folded night, weekends, week
  numbers, the week start, the clock and desktop notifications.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  defp open_display_options(lv),
    do: lv |> element("#calendar-display-options > button") |> render_click()

  # The ids inside one placement's display options, without its prefix, so
  # the toolbar's and the sheet's can be compared row for row.
  defp control_suffixes(lv, prefix) do
    lv
    |> element("##{prefix}-display-rows")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("[id]")
    |> Enum.flat_map(&Floki.attribute(&1, "id"))
    |> Enum.map(&String.replace_prefix(&1, prefix <> "-", ""))
  end

  # A wrapped toolbar once left the display options alone at the start of the
  # second row, so their right-aligned panel opened under the dashboard menu.
  test "the display options wrap with the views as one right-aligned group", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    for id <-
          ~w(calendar-search calendar-view-week calendar-focus-toggle calendar-display-options) do
      assert has_element?(lv, "#calendar-toolbar > #calendar-toolbar-end.ml-auto ##{id}")
    end
  end

  # German labels once pushed Kompakt and Sonntag out of a clipped strip.
  test "a row of segments can wrap them under its label", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_display_options(lv)

    for id <- ~w(calendar-density calendar-week-start calendar-time-format) do
      assert has_element?(lv, "div[class~='flex-wrap'] > ##{id}[class~='ml-auto']")
    end
  end

  # Opened under both strips and a wrapped toolbar, a panel capped at 80dvh
  # ran past the bottom of an 800px screen, so its last rows were out of reach.
  test "the display options panel is never taller than the room below the toolbar", %{
    conn: conn
  } do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open_display_options(lv)

    assert has_element?(
             lv,
             "#calendar-display-options [class~='max-h-[min(36rem,calc(100dvh-16rem))]'] #calendar-display-rows"
           )
  end

  test "compact density is saved and sent to the canvas", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)
    lv |> element("#calendar-density-compact") |> render_click()

    assert_push_event(lv, "calendar:settings", %{density: "compact"})
    assert CalendarPreferencesQueries.get_or_create(user.id).density == "compact"
    assert has_element?(lv, "#calendar-density-compact[aria-pressed='true']")
  end

  test "unfolding the night is saved and sent to the canvas", %{conn: conn} do
    %{conn: conn, user: user} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)
    lv |> element("#calendar-fold-night") |> render_click()

    assert_push_event(lv, "calendar:settings", %{fold_night: false})
    refute CalendarPreferencesQueries.get_or_create(user.id).fold_night
  end

  test "stored choices reach the canvas on its first request", %{conn: conn} do
    %{conn: conn} = owner(conn, preferences: [density: "compact", fold_night: false])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

    assert_reply(lv, %{settings: %{density: "compact", fold_night: false}})
  end

  test "the toolbar and the Calendars sheet offer the same display options", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)
    toolbar = control_suffixes(lv, "calendar")

    lv |> element("#calendar-phone-calendars") |> render_click()
    sheet = control_suffixes(lv, "calendar-sheet")

    assert toolbar == sheet

    assert Enum.all?(
             ~w(density-comfortable density-compact fold-night import-ics shortcuts-button),
             &(&1 in toolbar)
           )
  end

  test "neither display options nor the Calendars sheet offer the old calendar", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)
    lv |> element("#calendar-phone-calendars") |> render_click()

    refute has_element?(lv, "#calendar-back-to-old")
    refute has_element?(lv, "#calendar-sheet-back-to-old")
    refute render(lv) =~ "Back to the old calendar"
  end

  test "the toolbar's display options scroll within the window", %{conn: conn} do
    %{conn: conn} = owner(conn)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open_display_options(lv)

    assert has_element?(lv, "#calendar-display-options-panel.overflow-y-auto.w-80")
  end

  defp canvas(lv, event, params),
    do: lv |> element("#calendar-canvas") |> render_hook(event, params)

  defp stored(user), do: CalendarPreferencesQueries.get_or_create(user.id)

  describe "what the week shows" do
    test "hiding weekends is saved and reloads the window with a reset", %{conn: conn} do
      %{conn: conn, user: user} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open_display_options(lv)
      lv |> element("#calendar-weekends") |> render_click()

      assert_push_event(lv, "calendar:events", %{reset: true, settings: %{show_weekends: false}})
      refute stored(user).show_weekends
      assert has_element?(lv, "#calendar-weekends[aria-checked='false']")
    end

    test "a Sunday week start is saved and the window moves to Sunday-start weeks", %{
      conn: conn
    } do
      %{conn: conn, user: user} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open_display_options(lv)
      lv |> element("#calendar-week-start-sunday") |> render_click()

      # The week of Wed 14 October, one week either side: Sun 4 to Sat 24.
      assert_push_event(lv, "calendar:events", %{
        reset: true,
        range: %{from: "2026-10-04", to: "2026-10-25"},
        settings: %{week_start: "sunday"}
      })

      assert stored(user).week_start_day == "sunday"
      assert has_element?(lv, "#calendar-week-start-sunday[aria-pressed='true']")
    end

    test "week numbers are saved and sent to the canvas without a reload", %{conn: conn} do
      %{conn: conn, user: user} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open_display_options(lv)
      lv |> element("#calendar-week-numbers") |> render_click()

      assert_push_event(lv, "calendar:settings", %{show_week_numbers: true})
      refute_push_event(lv, "calendar:events", _payload)
      assert stored(user).show_week_numbers
    end

    test "the Calendars sheet sets the same preference as the toolbar", %{conn: conn} do
      %{conn: conn, user: user} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      canvas(lv, "calendar:toggle_menu", %{"menu" => "calendars"})
      lv |> element("#calendar-sheet-week-numbers") |> render_click()

      assert_push_event(lv, "calendar:settings", %{show_week_numbers: true})
      assert stored(user).show_week_numbers
    end

    test "a week start or clock the server does not know changes nothing", %{conn: conn} do
      %{conn: conn, user: user} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      canvas(lv, "calendar:set_week_start", %{"option" => "friday"})
      canvas(lv, "calendar:set_week_start", %{})
      canvas(lv, "calendar:set_time_format", %{"option" => "13h"})

      refute_push_event(lv, "calendar:events", _payload)
      refute_push_event(lv, "calendar:settings", _settings)
      assert stored(user).week_start_day == "monday"
      assert stored(user).time_format == "24h"
    end
  end

  describe "the clock" do
    test "12-hour is saved, sent to the canvas and kept when the dashboard renders again", %{
      conn: conn
    } do
      %{conn: conn, user: user} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open_display_options(lv)
      lv |> element("#calendar-time-format-12h") |> render_click()

      assert_push_event(lv, "calendar:settings", %{time_format: "12h"})
      assert stored(user).time_format == "12h"

      # A navigation renders DashboardLive again, which hands the surface its
      # own `time_format`: only a parent told of the change keeps 12-hour.
      canvas(lv, "calendar:goto", %{"view" => "day", "date" => "2026-10-15"})
      assert_patch(lv, "/dashboard/calendar?view=day&date=2026-10-15")
      canvas(lv, "calendar:ready", %{})

      assert_reply(lv, %{settings: %{time_format: "12h"}})
      open_display_options(lv)
      assert has_element?(lv, "#calendar-time-format-12h[aria-pressed='true']")
    end

    # The parent hands the surface the new clock, and that render used to
    # close whatever menu was open, the display options included.
    test "switching the clock back and forth keeps the display options open", %{conn: conn} do
      %{conn: conn} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_display_options(lv)

      for format <- ~w(12h 24h 12h) do
        lv |> element("#calendar-time-format-#{format}") |> render_click()
        assert has_element?(lv, "#calendar-time-format-#{format}[aria-pressed='true']")
      end
    end

    test "an open preview is rebuilt in the new clock", %{conn: conn} do
      %{conn: conn, integration: integration} = owner(conn)
      review = event(integration, "work", "Design review", ~U[2026-10-14 13:00:00Z])
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      canvas(lv, "calendar:open", %{"id" => "event-#{review.id}"})
      assert lv |> element("#calendar-preview") |> render() =~ "14:00"

      open_display_options(lv)
      lv |> element("#calendar-time-format-12h") |> render_click()

      assert lv |> element("#calendar-preview") |> render() =~ "2:00 PM"
    end
  end

  describe "desktop notifications" do
    test "switching them on is saved and sent to the canvas", %{conn: conn} do
      %{conn: conn, user: user} = owner(conn)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      open_display_options(lv)
      lv |> element("#calendar-desktop-reminders") |> render_click()

      assert_push_event(lv, "calendar:settings", %{desktop_reminders: true})
      assert stored(user).desktop_reminders_enabled
    end

    test "stored week numbers and notifications reach the canvas on its first request", %{
      conn: conn
    } do
      %{conn: conn} =
        owner(conn, preferences: [show_week_numbers: true, desktop_reminders_enabled: true])

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      canvas(lv, "calendar:ready", %{})

      assert_reply(lv, %{settings: %{show_week_numbers: true, desktop_reminders: true}})
    end
  end

  describe "touch targets" do
    test "every row of both placements reaches a 44px hit area on phones and coarse pointers",
         %{conn: conn} do
      %{conn: conn} = owner(conn)

      for prefix <- ["calendar", "calendar-sheet"] do
        {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

        if prefix == "calendar",
          do: open_display_options(lv),
          else: canvas(lv, "calendar:toggle_menu", %{"menu" => "calendars"})

        rows =
          lv
          |> element("##{prefix}-display-rows")
          |> render()
          |> Floki.parse_fragment!()

        controls =
          for suffix <- ~w(density week-start time-format),
              do: Floki.find(rows, "##{prefix}-#{suffix}")

        switches =
          for suffix <- ~w(fold-night weekends week-numbers desktop-reminders),
              do: Floki.find(rows, "##{prefix}-#{suffix}")

        # Anchor the lists: an id that stopped rendering must fail here.
        assert Enum.map(controls ++ switches, &length/1) == List.duplicate(1, 7)

        assert Enum.reject(controls, &(class_of(&1) =~ "max-sm:[&>button]:min-h-11")) == []

        assert Enum.reject(controls, &(class_of(&1) =~ "pointer-coarse:[&>button]:min-h-11")) ==
                 []

        # The shared coarse-pointer rule (buttons.css) pads `.status-toggle`.
        assert Enum.reject(switches, &(class_of(&1) =~ "status-toggle")) == []

        row_classes =
          rows
          |> Floki.find("##{prefix}-display-rows > div:not(.border-t)")
          |> Enum.map(&class_of/1)

        assert length(row_classes) == 8
        assert Enum.reject(row_classes, &(&1 =~ "max-sm:min-h-11")) == []
        assert Enum.reject(row_classes, &(&1 =~ "pointer-coarse:min-h-11")) == []

        import_button = Floki.find(rows, "##{prefix}-import-ics")
        assert class_of(import_button) =~ "max-sm:min-h-11"
      end
    end
  end

  defp class_of(node), do: node |> Floki.attribute("class") |> Enum.join(" ")
end
