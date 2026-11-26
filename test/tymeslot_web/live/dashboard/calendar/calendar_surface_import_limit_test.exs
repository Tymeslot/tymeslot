defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceImportLimitTest do
  @moduledoc """
  Importing an `.ics` file with more events than one import writes: the
  calendar says how many it will take and from when, and imports that many.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import TymeslotWeb.CalendarImportHelpers
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Repo

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    owner(conn)
  end

  describe "a file with more events than one import writes" do
    # 1,001 events on 1 May 2026 and a dentist's appointment in November; the
    # clock stands at 14 October 2026.
    defp oversized(busy_day \\ "20260501", dentist_day \\ "20261105") do
      busy =
        for n <- 1..1_001 do
          "BEGIN:VEVENT\r\nUID:busy#{n}@example.com\r\nSUMMARY:Busy #{n}\r\n" <>
            "DTSTART:#{busy_day}T090000Z\r\nDTEND:#{busy_day}T100000Z\r\nEND:VEVENT"
        end

      dentist =
        "BEGIN:VEVENT\r\nUID:dentist@example.com\r\nSUMMARY:Dentist\r\n" <>
          "DTSTART:#{dentist_day}T090000Z\r\nDTEND:#{dentist_day}T093000Z\r\nEND:VEVENT"

      Enum.join(["BEGIN:VCALENDAR", "VERSION:2.0"] ++ busy ++ [dentist, "END:VCALENDAR"], "\r\n")
    end

    defp option(lv, from), do: element(lv, ~s(#calendar-import-cutoff input[value="#{from}"]))

    test "offers the dates it fits from, and imports the events from the one chosen", %{
      conn: conn
    } do
      test_pid = self()

      expect(Tymeslot.CalendarMock, :create_event, 1, fn data, _context ->
        send(test_pid, {:written, data, self()})
        {:ok, CreatedEvent.new(data.uid)}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, oversized())

      dialogue = lv |> element("#calendar-import-too-many") |> render()
      assert dialogue =~ "This file holds 1,002 events, from 1 May 2026 to 5 November 2026."
      assert dialogue =~ "A repeating event counts once"
      assert dialogue =~ "subscribe to it by URL"
      refute has_element?(lv, "#calendar-import-start")

      # From 12 and 6 months back the busy day is kept and the file is still
      # too large; from 3 months back it is left out, so that is chosen.
      assert render(option(lv, "2025-10-14")) =~ "disabled"
      assert render(option(lv, "2026-04-14")) =~ "disabled"
      assert render(option(lv, "2026-07-14")) =~ "checked"
      assert dialogue =~ "1,002 events, more than 1,000"
      refute dialogue =~ "Export a shorter date range"

      # A date that does not fit is never taken, whatever the form sends.
      lv |> form("#calendar-import-cutoff") |> render_change(%{"from" => "2025-10-14"})
      assert render(option(lv, "2026-07-14")) =~ "checked"

      lv |> form("#calendar-import-cutoff") |> render_change(%{"from" => "2026-10-14"})
      assert render(option(lv, "2026-10-14")) =~ "checked"

      lv |> element("#calendar-import-narrow") |> render_click()
      render_async(lv)

      refute has_element?(lv, "#calendar-import-too-many")
      summary = lv |> element(~s([data-testid="calendar-import-summary"])) |> render()
      assert summary =~ "Found 1 event."
      assert summary =~ "1,001 events before 14 October 2026 are left out."

      start_import(lv)

      assert_receive {:written, %{summary: "Dentist"}, task}, task_timeout()
      await_task(task)

      settle(lv)
      assert has_element?(lv, "#calendar-import-result", "Imported 1 event.")
    end

    @all_ended "None of the events in this file fall within these dates"
    @too_many_from_today "Even the events from today onwards are more than one import can copy."
    @too_many_or_none "From each of these dates, this file holds either more events"

    # The dialogue for a file no date offered fits, with Continue disabled.
    defp none_fit_dialogue(conn, content) do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, content)

      assert render(element(lv, "#calendar-import-narrow")) =~ "disabled"
      lv |> element("#calendar-import-too-many") |> render()
    end

    test "says so when every event ended before the earliest date offered", %{conn: conn} do
      dialogue = none_fit_dialogue(conn, oversized("20250105", "20250106"))

      assert dialogue =~ "No events from this date on"
      assert dialogue =~ @all_ended
      refute dialogue =~ @too_many_from_today
      refute dialogue =~ @too_many_or_none
    end

    test "says so when even the events from today on are too many", %{conn: conn} do
      dialogue = none_fit_dialogue(conn, oversized("20261105", "20261106"))

      assert dialogue =~ @too_many_from_today
      refute dialogue =~ @all_ended
      refute dialogue =~ @too_many_or_none
    end

    test "says so when each date keeps too many events or none", %{conn: conn} do
      # From 12 and 6 months back all 1,002 are kept; from 3 months back none.
      dialogue = none_fit_dialogue(conn, oversized("20260501", "20260502"))

      assert dialogue =~ "1,002 events, more than 1,000"
      assert dialogue =~ "No events from this date on"
      assert dialogue =~ @too_many_or_none
      refute dialogue =~ @too_many_from_today
      refute dialogue =~ @all_ended
    end

    test "in German, groups the counts and the limit with a full stop", %{
      conn: conn,
      user: user
    } do
      user |> Changeset.change(locale: "de") |> Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, oversized())

      dialogue = lv |> element("#calendar-import-too-many") |> render()
      assert dialogue =~ "1.002 Ereignisse"
      assert dialogue =~ "1.000"
      refute dialogue =~ "1002"

      lv |> element("#calendar-import-narrow") |> render_click()
      render_async(lv)

      summary = lv |> element(~s([data-testid="calendar-import-summary"])) |> render()
      assert summary =~ "1.001 Ereignisse"
    end

    test "in Italian, puts the elided article before a range from the 8th to the 11th", %{
      conn: conn,
      user: user
    } do
      user |> Changeset.change(locale: "it") |> Repo.update!()

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      open_import(lv)
      upload(lv, oversized("20260508", "20261111"))

      dialogue = lv |> element("#calendar-import-too-many") |> render()
      assert dialogue =~ "1.002 eventi, dall&#39;8 maggio 2026 all&#39;11 novembre 2026."
    end
  end
end
