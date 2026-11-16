defmodule Tymeslot.CalendarGrid.BookablePayloadTest do
  @moduledoc """
  Bookable windows as the calendar canvas receives them: wall-clock minutes
  in the organiser's zone, one window even across midnight, and the real
  length kept when the clocks go back.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.CalendarGrid.BookablePayload

  @london "Europe/London"

  test "windows become wall-clock minutes in the organiser's zone" do
    windows = [%{start_at: ~U[2026-10-15 08:00:00.000000Z], end_at: ~U[2026-10-15 16:00:00Z]}]

    assert BookablePayload.windows(windows, @london) == [
             %{start: "2026-10-15T09:00", end: "2026-10-15T17:00"}
           ]
  end

  test "a window across midnight stays one window" do
    windows = [%{start_at: ~U[2026-10-15 21:00:00Z], end_at: ~U[2026-10-16 01:00:00Z]}]

    assert BookablePayload.windows(windows, @london) == [
             %{start: "2026-10-15T22:00", end: "2026-10-16T02:00"}
           ]
  end

  test "a window in the hour the clocks go back keeps its length" do
    # 01:30 summer time to 01:15 winter time: 45 minutes.
    windows = [%{start_at: ~U[2026-10-25 00:30:00Z], end_at: ~U[2026-10-25 01:15:00Z]}]

    assert BookablePayload.windows(windows, @london) == [
             %{start: "2026-10-25T01:30", end: "2026-10-25T02:15"}
           ]
  end

  test "wall/2 names one instant on the organiser's clock" do
    assert BookablePayload.wall(~U[2026-10-26 09:00:00Z], @london) == "2026-10-26T09:00"
    assert BookablePayload.wall(~U[2026-10-15 08:00:00Z], @london) == "2026-10-15T09:00"
  end
end
