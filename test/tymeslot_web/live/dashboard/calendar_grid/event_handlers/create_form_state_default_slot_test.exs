defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormStateDefaultSlotTest do
  @moduledoc """
  The slot quick add proposes when opened without a time (the `c` shortcut):
  the next whole hour for an hour, or tomorrow morning once that hour no
  longer fits into today. Pinned to fixed clock times, because the proposal
  depends on the time of day.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  import Tymeslot.Test.ClockHelpers

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState

  defp open_at(utc_time, timezone \\ "Etc/UTC") do
    freeze_clock(DateTime.new!(~D[2026-09-18], utc_time, "Etc/UTC"))

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, user_timezone: timezone, integrations: []}
    }

    {:noreply, socket} = CreateFormState.handle_show_create_form(%{}, socket)
    socket.assigns.creating_event
  end

  test "proposes the next whole hour, for an hour, today" do
    slot = open_at(~T[14:20:00])

    assert %{date: "2026-09-18", start_hour: 15, end_hour: 16} = slot
  end

  test "starts at the current hour when it is exactly on the hour" do
    assert %{start_hour: 14, end_hour: 15} = open_at(~T[14:00:00])
  end

  test "still fits a slot ending at 23:00" do
    assert %{date: "2026-09-18", start_hour: 22, end_hour: 23} = open_at(~T[21:40:00])
  end

  test "moves to tomorrow morning when the next hour would run into midnight" do
    # Used to open 23:00-00:00 on the same date, which the save refuses.
    slot = open_at(~T[22:30:00])

    assert %{date: "2026-09-19", end_date: "2026-09-19", start_hour: 9, end_hour: 10} = slot
  end

  test "moves to tomorrow morning in the last hour of the day" do
    # Used to open 00:00-01:00 on today's date, already in the past.
    assert %{date: "2026-09-19", start_hour: 9, end_hour: 10} = open_at(~T[23:30:00])
  end

  test "counts the hours in the user's own timezone" do
    # 20:30 UTC is 22:30 in Berlin (CEST): too late for a slot today there.
    assert %{date: "2026-09-19", start_hour: 9} = open_at(~T[20:30:00], "Europe/Berlin")
  end
end
