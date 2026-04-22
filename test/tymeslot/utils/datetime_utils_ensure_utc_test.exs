defmodule Tymeslot.Utils.DateTimeUtilsEnsureUtcTest do
  @moduledoc """
  Pins the tagged-tuple contract introduced to stop `ensure_utc/1` from
  silently returning the original DateTime when `DateTime.shift_zone/2` fails.

  The previous signature `DateTime.t() -> DateTime.t()` plus a
  warning-log-and-return-original branch meant a tz-database failure surfaced
  downstream as a wrong-zone iCal/CalDAV string — the reader assumed a UTC
  datetime per `Z` suffix when it was actually the source zone's wall clock.
  The fix changes the signature to `{:ok, DateTime.t()} | {:error, term()}`
  and introduces `ensure_utc!/1` for callers whose contract is
  `DateTime.t() -> String.t()` (iCal/CalDAV formatters) — they raise loudly
  rather than produce a wrong-zone string.

  `async: false` because these tests mutate the application-wide default via
  `Calendar.put_time_zone_database/1`.
  """

  use ExUnit.Case, async: false

  @moduletag :utils

  alias Tymeslot.Utils.DateTimeUtils

  defmodule AlwaysErrorTzDb do
    @moduledoc false
    @behaviour Calendar.TimeZoneDatabase

    @impl Calendar.TimeZoneDatabase
    def time_zone_period_from_utc_iso_days(_iso_days, _time_zone),
      do: {:error, :stubbed_tz_db_failure}

    @impl Calendar.TimeZoneDatabase
    def time_zone_periods_from_wall_datetime(_naive, _time_zone),
      do: {:error, :stubbed_tz_db_failure}
  end

  setup do
    original_db = Calendar.get_time_zone_database()
    on_exit(fn -> Calendar.put_time_zone_database(original_db) end)
    :ok
  end

  describe "ensure_utc/1" do
    test "UTC input short-circuits to {:ok, dt}" do
      dt = ~U[2024-06-01 12:00:00Z]
      assert {:ok, ^dt} = DateTimeUtils.ensure_utc(dt)
    end

    test "non-UTC input with a working tz db shifts and returns {:ok, utc_dt}" do
      ny = DateTime.new!(~D[2024-06-01], ~T[12:00:00], "America/New_York")
      # New York in June = EDT (UTC-4)
      assert {:ok, utc_dt} = DateTimeUtils.ensure_utc(ny)
      assert utc_dt.time_zone == "Etc/UTC"
      assert utc_dt == ~U[2024-06-01 16:00:00Z]
    end

    test "tz db failure returns {:error, reason} instead of the original DateTime" do
      # Construct a non-UTC DateTime *before* swapping in the broken db; a
      # valid source tz is needed so we isolate the failure to the shift call.
      ny = DateTime.new!(~D[2024-06-01], ~T[12:00:00], "America/New_York")

      Calendar.put_time_zone_database(AlwaysErrorTzDb)

      assert {:error, :stubbed_tz_db_failure} = DateTimeUtils.ensure_utc(ny)
    end
  end

  describe "ensure_utc!/1" do
    test "unwraps the tuple on success" do
      ny = DateTime.new!(~D[2024-06-01], ~T[12:00:00], "America/New_York")
      assert %DateTime{time_zone: "Etc/UTC"} = DateTimeUtils.ensure_utc!(ny)
    end

    test "raises ArgumentError on shift_zone failure rather than silently passing through" do
      ny = DateTime.new!(~D[2024-06-01], ~T[12:00:00], "America/New_York")
      Calendar.put_time_zone_database(AlwaysErrorTzDb)

      assert_raise ArgumentError, ~r/failed to shift .* to UTC/, fn ->
        DateTimeUtils.ensure_utc!(ny)
      end
    end
  end
end
