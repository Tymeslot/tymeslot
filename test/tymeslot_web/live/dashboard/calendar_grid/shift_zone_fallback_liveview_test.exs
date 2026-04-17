defmodule TymeslotWeb.Dashboard.CalendarGrid.ShiftZoneFallbackLiveViewTest do
  use TymeslotWeb.LiveCase, async: true

  import ExUnit.CaptureLog
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @moduletag :calendar
  @moduletag :live

  alias Plug.Test

  # End-to-end wiring test for the invalid-timezone crash-prevention guarantee.
  # Complements the unit tests in shift_zone_fallback_test.exs by mounting the
  # full calendar LiveView with a user whose persisted profile.timezone is an
  # unknown IANA zone (simulating corrupted data or a retired zone). The page
  # must render without raising, and a single warning must be logged.

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  test "mounts the calendar without crashing when profile.timezone is invalid",
       %{conn: conn, user: user} do
    # ExMachina bypasses the changeset validation, simulating a timezone that
    # was valid when stored but is no longer recognised by the tz database.
    _profile = insert(:profile, user: user, timezone: "Not/A_Real_Zone")

    {result, log} =
      with_log(fn ->
        live(conn, ~p"/dashboard/calendar")
      end)

    assert {:ok, _lv, html} = result
    assert html =~ "calendar"
    assert log =~ "Invalid user timezone"
  end
end
