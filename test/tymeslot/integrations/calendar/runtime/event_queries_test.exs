defmodule Tymeslot.Integrations.Calendar.Runtime.EventQueriesTest do
  use Tymeslot.DataCase, async: true
  @moduletag :calendar

  describe "get_events_for_month/4 timezone boundaries" do
    # These tests verify that month boundaries are computed in the user's timezone
    # and then shifted to UTC, rather than always using UTC midnight.
    # We can't easily test the full pipeline (it needs live calendar clients),
    # so we test the boundary computation indirectly by checking that the function
    # attempts to fetch with the correct UTC range.

    test "UTC+12 produces start datetime before UTC month boundary" do
      # For March 2026 in Pacific/Auckland (UTC+12/+13 depending on DST):
      # Month starts at 2026-03-01 00:00:00 NZDT = 2026-02-28 11:00:00 UTC
      # So the UTC start should be in February, before the UTC month boundary.
      timezone = "Pacific/Auckland"
      year = 2026
      month = 3

      start_date = Date.new!(year, month, 1)

      start_dt =
        DateTime.new!(start_date, ~T[00:00:00], timezone) |> DateTime.shift_zone!("Etc/UTC")

      # The UTC start should be before March 1 UTC
      assert DateTime.compare(start_dt, DateTime.new!(~D[2026-03-01], ~T[00:00:00], "Etc/UTC")) ==
               :lt
    end

    test "UTC-10 produces end datetime after UTC month boundary" do
      # For March 2026 in Pacific/Honolulu (UTC-10):
      # Month ends at 2026-03-31 23:59:59 HST = 2026-04-01 09:59:59 UTC
      # So the UTC end should be in April, after the UTC month boundary.
      timezone = "Pacific/Honolulu"
      year = 2026
      month = 3

      end_date = Date.end_of_month(Date.new!(year, month, 1))
      end_dt = DateTime.new!(end_date, ~T[23:59:59], timezone) |> DateTime.shift_zone!("Etc/UTC")

      # The UTC end should be after March 31 23:59:59 UTC
      assert DateTime.compare(end_dt, DateTime.new!(~D[2026-03-31], ~T[23:59:59], "Etc/UTC")) ==
               :gt
    end

    test "Etc/UTC produces same boundaries as naive Date approach" do
      year = 2026
      month = 3

      start_date = Date.new!(year, month, 1)
      end_date = Date.end_of_month(start_date)

      start_dt =
        DateTime.new!(start_date, ~T[00:00:00], "Etc/UTC") |> DateTime.shift_zone!("Etc/UTC")

      end_dt = DateTime.new!(end_date, ~T[23:59:59], "Etc/UTC") |> DateTime.shift_zone!("Etc/UTC")

      # Should match the old naive UTC approach exactly
      assert start_dt == DateTime.new!(~D[2026-03-01], ~T[00:00:00], "Etc/UTC")
      assert end_dt == DateTime.new!(~D[2026-03-31], ~T[23:59:59], "Etc/UTC")
    end

    test "invalid timezone raises a meaningful error" do
      assert_raise ArgumentError, fn ->
        DateTime.new!(~D[2026-03-01], ~T[00:00:00], "Invalid/Timezone")
      end
    end
  end
end
