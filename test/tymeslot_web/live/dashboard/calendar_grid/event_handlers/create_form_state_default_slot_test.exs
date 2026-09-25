defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormStateDefaultSlotTest do
  @moduledoc """
  The slot quick add proposes when opened without a time (the `c` shortcut):
  the next whole hour, for an hour, in the user's own timezone. Pinned to fixed
  clock times, because the proposal depends on the time of day, and because the
  cases that matter are the ones where the hour after next is on another date
  or on the other side of a DST transition.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  import Tymeslot.Test.ClockHelpers

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  defp open_at(utc_datetime, timezone \\ "Etc/UTC") do
    freeze_clock(utc_datetime)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, user_timezone: timezone, integrations: []}
    }

    {:noreply, socket} = CreateFormState.handle_show_create_form(%{}, socket)
    socket.assigns.creating_event
  end

  # The proposal is only useful if the form it fills can be saved, and the save
  # path resolves each end against the timezone before comparing them. Asserting
  # the hours alone would miss a slot whose two ends collapse onto one instant.
  defp saveable?(slot, timezone \\ "Etc/UTC") do
    {:ok, start_date} = Date.from_iso8601(slot.date)
    {:ok, end_date} = Date.from_iso8601(slot.end_date)
    {:ok, start_at} = Shared.to_utc(start_date, slot.start_hour, slot.start_minute, timezone)
    {:ok, end_at} = Shared.to_utc(end_date, slot.end_hour, slot.end_minute, timezone)

    DateTime.compare(end_at, start_at) == :gt
  end

  test "proposes the next whole hour, for an hour, today" do
    slot = open_at(~U[2026-09-18 14:20:00Z])

    assert %{date: "2026-09-18", end_date: "2026-09-18", start_hour: 15, end_hour: 16} = slot
    assert saveable?(slot)
  end

  test "starts at the current hour when it is exactly on the hour" do
    assert %{start_hour: 14, end_hour: 15} = open_at(~U[2026-09-18 14:00:00Z])
  end

  test "still fits a slot ending at 23:00" do
    assert %{date: "2026-09-18", start_hour: 22, end_hour: 23} = open_at(~U[2026-09-18 21:40:00Z])
  end

  test "ends the slot on the next date when the hour runs into midnight" do
    # Used to open 23:00-00:00 on one date, which the save refuses.
    slot = open_at(~U[2026-09-18 22:30:00Z])

    assert %{date: "2026-09-18", end_date: "2026-09-19", start_hour: 23, end_hour: 0} = slot
    assert saveable?(slot)
  end

  test "opens on the next date once the next whole hour is already tomorrow" do
    # Used to open 00:00-01:00 on today's date, a slot already in the past.
    slot = open_at(~U[2026-09-18 23:30:00Z])

    assert %{date: "2026-09-19", end_date: "2026-09-19", start_hour: 0, end_hour: 1} = slot
    assert saveable?(slot)
  end

  test "counts the hours in the user's own timezone" do
    # 20:30 UTC is 22:30 in Berlin (CEST), so the slot crosses midnight there.
    slot = open_at(~U[2026-09-18 20:30:00Z], "Europe/Berlin")

    assert %{date: "2026-09-18", end_date: "2026-09-19", start_hour: 23, end_hour: 0} = slot
    assert saveable?(slot, "Europe/Berlin")
  end

  test "steps past the hour a fall-back DST transition repeats" do
    # 01:30 CEST in Berlin on the night the clocks go back: 02:00 plus an hour
    # is 02:00 again, so both ends of the slot used to read as hour 2 and the
    # save refused a proposal of no length.
    slot = open_at(~U[2026-10-24 23:30:00Z], "Europe/Berlin")

    assert %{date: "2026-10-25", end_date: "2026-10-25", start_hour: 2, end_hour: 3} = slot
    assert saveable?(slot, "Europe/Berlin")
  end

  test "skips the hour a spring-forward DST transition removes" do
    # 01:20 CET in Berlin: 02:00 does not exist that night, so both ends of a
    # 02:00-03:00 slot would resolve to 03:00 and the save would be refused.
    slot = open_at(~U[2027-03-28 00:20:00Z], "Europe/Berlin")

    assert %{date: "2027-03-28", end_date: "2027-03-28", start_hour: 3, end_hour: 4} = slot
    assert saveable?(slot, "Europe/Berlin")
  end
end
