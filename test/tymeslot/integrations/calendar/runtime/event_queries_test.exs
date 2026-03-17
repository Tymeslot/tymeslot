defmodule Tymeslot.Integrations.Calendar.Runtime.EventQueriesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Runtime.EventQueries

  describe "month_utc_boundaries/3" do
    test "UTC+12 produces start datetime before UTC month boundary" do
      # March 2026 in Pacific/Auckland (UTC+13 during NZDT):
      # 2026-03-01 00:00:00 NZDT = 2026-02-28 11:00:00 UTC
      {start_dt, _end_dt} = EventQueries.month_utc_boundaries(2026, 3, "Pacific/Auckland")

      assert DateTime.compare(start_dt, DateTime.new!(~D[2026-03-01], ~T[00:00:00], "Etc/UTC")) ==
               :lt
    end

    test "UTC-10 produces end datetime after UTC month boundary" do
      # March 2026 in Pacific/Honolulu (UTC-10):
      # 2026-03-31 23:59:59 HST = 2026-04-01 09:59:59 UTC
      {_start_dt, end_dt} = EventQueries.month_utc_boundaries(2026, 3, "Pacific/Honolulu")

      assert DateTime.compare(end_dt, DateTime.new!(~D[2026-03-31], ~T[23:59:59], "Etc/UTC")) ==
               :gt
    end

    test "Etc/UTC produces same boundaries as naive Date approach" do
      {start_dt, end_dt} = EventQueries.month_utc_boundaries(2026, 3, "Etc/UTC")

      assert start_dt == DateTime.new!(~D[2026-03-01], ~T[00:00:00], "Etc/UTC")
      assert end_dt == DateTime.new!(~D[2026-03-31], ~T[23:59:59], "Etc/UTC")
    end

    test "invalid timezone raises" do
      assert_raise ArgumentError, fn ->
        EventQueries.month_utc_boundaries(2026, 3, "Invalid/Timezone")
      end
    end
  end
end
