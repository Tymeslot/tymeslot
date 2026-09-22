defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormStateAllDayTest do
  @moduledoc """
  What ticking All-day does to the range quick add already holds. The case that
  matters is the one where the timed default has run into the following day, so
  the two ends carry different dates before the box is ever ticked.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  import Tymeslot.Test.ClockHelpers

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState

  defp open_at(utc_datetime, timezone \\ "Etc/UTC") do
    freeze_clock(utc_datetime)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, user_timezone: timezone, integrations: []}
    }

    {:noreply, socket} = CreateFormState.handle_show_create_form(%{}, socket)
    socket
  end

  defp toggle(socket) do
    {:noreply, socket} = CreateFormState.handle_toggle_create_all_day(%{}, socket)
    socket
  end

  test "collapses a range that runs into tomorrow onto the start's day" do
    # 23:30-00:30 is the default between 22:01 and 23:00; ticking All-day on it
    # used to propose a two-day banner, which is never what was meant.
    socket = open_at(~U[2026-09-18 22:30:00Z])
    assert %{date: "2026-09-18", end_date: "2026-09-19"} = socket.assigns.creating_event

    creating = toggle(socket).assigns.creating_event

    assert creating.all_day
    assert creating.end_date == creating.date
    assert creating.date == "2026-09-18"
  end

  test "leaves a same-day range alone" do
    creating =
      ~U[2026-09-18 14:20:00Z] |> open_at() |> toggle() |> then(& &1.assigns.creating_event)

    assert creating.all_day
    assert creating.date == "2026-09-18"
    assert creating.end_date == "2026-09-18"
  end

  test "does not re-collapse a widened range when All-day is switched off" do
    # A user who deliberately widened an all-day event to several days and then
    # unticks the box has said what they want; only switching on collapses.
    socket = open_at(~U[2026-09-18 14:20:00Z])

    widened =
      put_in(socket.assigns.creating_event, %{
        socket.assigns.creating_event
        | all_day: true,
          end_date: "2026-09-21"
      })

    creating = widened |> toggle() |> then(& &1.assigns.creating_event)

    refute creating.all_day
    assert creating.end_date == "2026-09-21"
  end

  test "is a no-op when no create form is open" do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, creating_event: nil}}

    assert {:noreply, ^socket} = CreateFormState.handle_toggle_create_all_day(%{}, socket)
  end
end
