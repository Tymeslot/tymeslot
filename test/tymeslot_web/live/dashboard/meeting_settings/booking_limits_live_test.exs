defmodule TymeslotWeb.Dashboard.MeetingSettings.BookingLimitsLiveTest do
  @moduledoc """
  The two places a host caps their bookings: across every meeting type on the
  meeting types page, and per meeting type in its editor. Both render the same
  fields; these check each still saves.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :meeting_types
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles

  setup :setup_dashboard_user

  describe "Booking limits" do
    test "a meeting type's per-day cap is saved as it is typed", %{conn: conn, user: user} do
      meeting_type = insert(:meeting_type, user: user)

      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      view
      |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
      |> render_click()

      view
      |> element("#meeting-type-booking-limits-max_bookings_per_day")
      |> render_change(%{"meeting_type" => %{"max_bookings_per_day" => "4"}})

      assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).max_bookings_per_day == 4

      assert has_element?(
               view,
               ~s|#meeting-type-booking-limits-max_bookings_per_day[value="4"]|
             )
    end

    test "the account-wide weekly cap is saved and confirmed", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

      assert has_element?(view, "#booking-limits-heading", "Booking Limits")

      view
      |> form("#booking-limits-form")
      |> render_change(%{"_target" => ["max_bookings_per_week"], "max_bookings_per_week" => "12"})

      assert Profiles.get_profile(user.id).max_bookings_per_week == 12
      assert render(view) =~ "Booking limit updated to 12 bookings"
    end
  end
end
