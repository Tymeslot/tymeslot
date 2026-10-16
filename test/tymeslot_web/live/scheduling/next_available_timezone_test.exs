defmodule TymeslotWeb.Live.Scheduling.NextAvailableTimezoneTest do
  @moduledoc """
  Unit coverage for `NextAvailable.follow_timezone_change/1`: which selections
  a change of timezone drops and re-lands, and which it keeps. The journeys
  through the booking page are in `TimezoneChangeSelectionTest`.
  """

  use ExUnit.Case, async: true

  @moduletag :scheduling

  import Tymeslot.Test.ClockHelpers

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.CalendarHelpers
  alias TymeslotWeb.Live.Scheduling.NextAvailable

  # A schedule step in Tallinn whose landing attempt has been spent.
  @spent_landing %{
    __changed__: %{},
    current_state: :schedule,
    user_timezone: "Europe/Tallinn",
    week_start: :monday,
    booking_window_days: 90,
    selected_date: nil,
    selected_time: nil,
    auto_select_settled: true,
    auto_select_months_searched: 0
  }

  describe "follow_timezone_change/1" do
    # Sunday 31 January in Tallinn, already Monday 1 February in Kiritimati.
    setup do
      freeze_clock(~U[2027-01-31 12:00:00Z])
      :ok
    end

    # A page opened in Tallinn that landed on today, 31 January, as its first
    # free day and spent the attempt; the booker has then picked Kiritimati.
    defp landed_then_switched(changes \\ %{}, week_start \\ :monday) do
      %Socket{assigns: Map.put(@spent_landing, :week_start, week_start)}
      |> CalendarHelpers.anchor_on_today()
      |> put_assigns(%{selected_date: "2027-01-31"})
      |> CalendarHelpers.land_on(~D[2027-01-31])
      |> put_assigns(Map.put(changes, :user_timezone, "Pacific/Kiritimati"))
    end

    defp put_assigns(socket, assigns), do: %{socket | assigns: Map.merge(socket.assigns, assigns)}

    test "drops the day it landed on and re-arms on the new zone's today" do
      socket = NextAvailable.follow_timezone_change(landed_then_switched())

      assert %{
               selected_date: nil,
               selected_time: nil,
               calendar_today: ~D[2027-02-01],
               current_month: 2,
               current_week_start: ~D[2027-02-01],
               auto_select_settled: false,
               auto_select_months_searched: 0
             } = socket.assigns
    end

    test "re-arms on the new zone's week as the visitor's week start has it" do
      # Monday 1 February in Kiritimati sits in the Sunday-started week of
      # 31 January.
      socket =
        NextAvailable.follow_timezone_change(landed_then_switched(%{}, :sunday))

      assert %{
               selected_date: nil,
               calendar_today: ~D[2027-02-01],
               current_week_start: ~D[2027-01-31],
               auto_select_settled: false
             } = socket.assigns
    end

    test "keeps a day the booker chose" do
      socket =
        NextAvailable.follow_timezone_change(landed_then_switched(%{selected_date: "2027-02-03"}))

      assert %{
               selected_date: "2027-02-03",
               calendar_today: ~D[2027-01-31],
               auto_select_settled: true
             } = socket.assigns
    end

    test "drops a held day that has passed in the new zone, and re-arms" do
      # Moved off the landing (here by the month arrows' position), so not
      # untouched; 31 January is already past in Kiritimati all the same.
      socket =
        NextAvailable.follow_timezone_change(landed_then_switched(%{current_month: 2}))

      assert %{
               selected_date: nil,
               calendar_today: ~D[2027-02-01],
               current_week_start: ~D[2027-02-01],
               auto_select_settled: false
             } = socket.assigns
    end

    test "keeps a week the booker moved to with no day selected" do
      socket =
        NextAvailable.follow_timezone_change(
          landed_then_switched(%{current_week_start: ~D[2027-02-08], selected_date: nil})
        )

      assert %{
               selected_date: nil,
               current_week_start: ~D[2027-02-08],
               auto_select_settled: true
             } = socket.assigns
    end
  end
end
