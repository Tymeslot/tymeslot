defmodule TymeslotWeb.Dashboard.CalendarGrid.ShiftZoneFallbackTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Profiles
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.DataLoading

  # The calendar grid resolves the user's timezone once, at the LiveView edge
  # (precompute_derived/1), by the owner-zone rule (Tymeslot.Profiles.timezone/1),
  # so every downstream helper can shift into it safely. A stored zone the
  # time-zone database does not know reads as the default zone, the clock the
  # booking engine reads the same host on, and is logged once.

  @bad_tz "Not/A_Real_Zone"
  @good_tz "Europe/London"

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

    test "assigns the default zone when the profile timezone is invalid" do
      socket = build_socket(@bad_tz)
      result = DataLoading.precompute_derived(socket)
      assert result.assigns.user_timezone == Profiles.get_default_timezone()
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
