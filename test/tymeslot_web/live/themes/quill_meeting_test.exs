defmodule TymeslotWeb.Live.Themes.QuillMeetingTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  alias TymeslotWeb.ThemeMeetingTestCases

  setup do
    ThemeMeetingTestCases.setup_theme_meeting(%{
      user_name: "Jane Smith",
      theme_id: "1",
      username: "jane",
      color_scheme: "turquoise",
      background_value: "gradient_2",
      start_time: DateTime.add(DateTime.utc_now(), 1, :day),
      duration: 45,
      # Non-UTC, DST-free zone: proves the reschedule page actually shifts
      # the rendered clock rather than showing the raw stored UTC value.
      attendee_timezone: "Asia/Kathmandu"
    })
  end

  describe "Cancel Confirmed Page" do
    setup %{conn: conn, profile: profile, meeting: meeting} do
      ThemeMeetingTestCases.setup_cancel_confirmed_view(conn, profile, meeting)
    end

    # The assertions live in the shared ThemeMeetingTestCases helper, which the
    # check cannot see because the helper name does not start with `assert_`.
    # credo:disable-for-next-line Jump.CredoChecks.TestHasNoAssertions
    test "renders and handles navigation", %{view: view} do
      ThemeMeetingTestCases.test_cancel_confirmed_page(view)
    end
  end

  describe "Reschedule Page" do
    setup %{conn: conn, profile: profile, meeting: meeting} do
      ThemeMeetingTestCases.setup_reschedule_view(conn, profile, meeting)
    end

    test "renders the reschedule page with quill style and meeting details", %{
      view: view,
      meeting: meeting
    } do
      ThemeMeetingTestCases.test_reschedule_page_rendering(view)
      ThemeMeetingTestCases.assert_meeting_details_rendered(view, meeting, "Jane Smith", 45)
    end

    # The assertions live in the shared ThemeMeetingTestCases helper, which the
    # check cannot see because the helper name does not start with `assert_`.
    # credo:disable-for-next-line Jump.CredoChecks.TestHasNoAssertions
    test "Choose New Time button navigates back to profile carrying the reschedule uid", %{
      view: view,
      profile: profile,
      meeting: meeting
    } do
      ThemeMeetingTestCases.test_reschedule_page_navigation(
        view,
        "Choose New Time",
        profile.username,
        meeting.uid
      )
    end
  end

  @tag :capture_log
  # The assertions live in the shared ThemeMeetingTestCases helper, which the
  # check cannot see because the helper name does not start with `assert_`.
  # credo:disable-for-next-line Jump.CredoChecks.TestHasNoAssertions
  test "meeting pages render translated strings in non-English locale", %{conn: conn} = context do
    ThemeMeetingTestCases.test_all_meeting_pages_in_locale(conn, context, "de")
  end
end
