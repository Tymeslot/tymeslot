defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceShortcutsTest do
  @moduledoc """
  The calendar's shortcut help: opened by ?, by display options in the
  toolbar and in the Calendars sheet, closed like any surface menu, and the
  screen-reader hints that point at it and spell the keys out.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import TymeslotWeb.CalendarSurfaceHelpers

  setup %{conn: conn}, do: owner(conn)

  # What ? sends from the canvas hook.
  defp press_question_mark(lv),
    do:
      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:toggle_menu", %{"menu" => "shortcuts"})

  test "? opens the help with every group and its keys", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    # Rendered only while open: the hook's MODALS selector matches its id.
    refute has_element?(lv, "#calendar-shortcuts")

    press_question_mark(lv)

    assert has_element?(lv, "#calendar-shortcuts [role='dialog']", "Keyboard shortcuts")

    for group <- ["Navigate", "Create and change", "Calendars", "Anywhere"],
        do: assert(has_element?(lv, "#calendar-shortcuts h3", group))

    assert has_element?(lv, "#calendar-shortcuts kbd", "T")
    assert has_element?(lv, "#calendar-shortcuts kbd", "F")
    assert has_element?(lv, "#calendar-shortcuts kbd", "0")
    assert has_element?(lv, "#calendar-shortcuts", "Search and commands (Cmd K on a Mac)")
    assert has_element?(lv, "#calendar-shortcuts", "Apply calendar set 1 to 9")
  end

  test "the close button and Esc's event close it", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    press_question_mark(lv)
    lv |> element("#calendar-shortcuts .modal-close") |> render_click()
    refute has_element?(lv, "#calendar-shortcuts")

    press_question_mark(lv)
    lv |> element("#calendar-canvas") |> render_hook("calendar:close_menu", %{})
    refute has_element?(lv, "#calendar-shortcuts")
  end

  test "? again closes it, and another menu replaces it", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    press_question_mark(lv)
    assert has_element?(lv, "#calendar-shortcuts")
    press_question_mark(lv)
    refute has_element?(lv, "#calendar-shortcuts")

    press_question_mark(lv)
    assert has_element?(lv, "#calendar-shortcuts")
    lv |> element("#calendar-display-options > button") |> render_click()
    refute has_element?(lv, "#calendar-shortcuts")
  end

  test "display options in the toolbar open it", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-display-options > button") |> render_click()
    lv |> element("#calendar-shortcuts-button") |> render_click()

    assert has_element?(lv, "#calendar-shortcuts")
    # The dropdown's panel renders only while it is the open menu.
    refute has_element?(lv, "#calendar-density")
  end

  test "display options in the Calendars sheet open it in place of the sheet", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv |> element("#calendar-phone-calendars") |> render_click()
    lv |> element("#calendar-sheet-shortcuts-button") |> render_click()

    assert has_element?(lv, "#calendar-shortcuts")
    refute has_element?(lv, "#calendar-calendars-sheet")
  end

  test "the screen-reader hints point at the help and spell the keys out", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert has_element?(lv, "#calendar-keys-hint", "E to edit it")
    assert has_element?(lv, "#calendar-keys-hint", "Press B to show or hide your bookable times.")
    assert has_element?(lv, "#calendar-keys-hint", "Press ? to see every keyboard shortcut.")

    assert has_element?(
             lv,
             "#calendar-shortcuts-hint.sr-only",
             "J and K for the next and previous period"
           )

    refute has_element?(lv, "#calendar-keys-hint", "J and K")
  end

  describe "focus after the display options' modals close" do
    @ids ["calendar-display-toggle", "calendar-phone-calendars"]

    test "the help opened from display options hands focus back to the toggle", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-display-options > button") |> render_click()
      lv |> element("#calendar-shortcuts-button") |> render_click()
      lv |> element("#calendar-shortcuts .modal-close") |> render_click()

      assert_push_event(lv, "calendar:focus", %{ids: @ids})
    end

    test "the help opened by ? leaves focus to the modal's own restore", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      press_question_mark(lv)
      lv |> element("#calendar-shortcuts .modal-close") |> render_click()

      refute_push_event(lv, "calendar:focus", _)
    end

    test "the import modal opened from display options hands focus back", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv |> element("#calendar-display-options > button") |> render_click()
      lv |> element("#calendar-import-ics") |> render_click()
      lv |> element("#calendar-import .modal-close") |> render_click()

      assert_push_event(lv, "calendar:focus", %{ids: @ids})
    end
  end
end
