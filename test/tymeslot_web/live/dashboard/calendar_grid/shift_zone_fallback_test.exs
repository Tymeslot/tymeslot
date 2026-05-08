defmodule TymeslotWeb.Dashboard.CalendarGrid.ShiftZoneFallbackTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Timezones
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading

  # Tests the single validation point for invalid user timezones in the calendar
  # grid. The strategy is: validate ONCE at the LiveView edge (precompute_derived/1)
  # so that all downstream helpers can use bang variants safely. The load-bearing
  # behaviour is Tymeslot.Timezones.validate_or_utc/2 and its use in
  # DataLoading.precompute_derived/1.

  @bad_tz "Not/A_Real_Zone"
  @good_tz "Europe/London"

  # ---------------------------------------------------------------------------
  # Tymeslot.Timezones.validate_or_utc/2 — the edge-validation function
  # ---------------------------------------------------------------------------

  describe "Timezones.validate_or_utc/2" do
    test "returns a valid timezone unchanged" do
      assert Timezones.validate_or_utc(@good_tz) == @good_tz
    end

    test "returns 'Etc/UTC' for an unknown IANA zone" do
      assert Timezones.validate_or_utc(@bad_tz) == "Etc/UTC"
    end

    test "returns 'Etc/UTC' for an empty string" do
      assert Timezones.validate_or_utc("") == "Etc/UTC"
    end

    test "emits a stable warning message when falling back" do
      log =
        capture_log(fn ->
          Timezones.validate_or_utc(@bad_tz, user_id: 42)
        end)

      assert log =~ "Invalid user timezone"
    end

    test "logs exactly once per call (not per downstream use)" do
      logs =
        capture_log(fn ->
          Timezones.validate_or_utc(@bad_tz, user_id: 1)
        end)

      # A single warning line — the message does not repeat.
      occurrences = logs |> String.split("Invalid user timezone") |> length()
      # split produces (n+1) parts for n occurrences
      assert occurrences == 2
    end

    test "does not log for a valid timezone" do
      # capture_log/1 captures from every process in the VM, so unrelated logs
      # from concurrent async tests can leak in. Assert the absence of this
      # function's specific warning rather than the entire log being empty.
      log =
        capture_log(fn ->
          Timezones.validate_or_utc(@good_tz, user_id: 99)
        end)

      refute log =~ "Invalid user timezone"
    end
  end

  # ---------------------------------------------------------------------------
  # DataLoading.precompute_derived/1 — the call site
  # ---------------------------------------------------------------------------
  #
  # A minimal fake socket (plain map with an :assigns key) is sufficient because
  # Phoenix.Component.assign/3 operates on any %{assigns: map} struct.

  describe "DataLoading.precompute_derived/1 with an invalid user timezone" do
    defp build_socket(timezone) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          profile: %{timezone: timezone},
          current_user: %{id: 7},
          events: [],
          hidden_integration_ids: [],
          view: :week,
          date: ~D[2026-04-14],
          preferences: %{week_start: :monday, show_weekends: true}
        }
      }
    end

    test "assigns 'Etc/UTC' when the profile timezone is invalid" do
      socket = build_socket(@bad_tz)
      result = DataLoading.precompute_derived(socket)
      assert result.assigns.user_timezone == "Etc/UTC"
    end

    test "preserves a valid timezone unchanged" do
      socket = build_socket(@good_tz)
      result = DataLoading.precompute_derived(socket)
      assert result.assigns.user_timezone == @good_tz
    end

    test "logs exactly once on bad timezone at mount time" do
      socket = build_socket(@bad_tz)

      log =
        capture_log(fn ->
          DataLoading.precompute_derived(socket)
        end)

      assert log =~ "Invalid user timezone"

      occurrences = log |> String.split("Invalid user timezone") |> length()
      assert occurrences == 2
    end

    test "does not log for a valid timezone" do
      socket = build_socket(@good_tz)

      log =
        capture_log(fn ->
          DataLoading.precompute_derived(socket)
        end)

      refute log =~ "Invalid user timezone"
    end
  end
end
