defmodule TymeslotWeb.Live.Themes.QuillMeetingTest do
  use TymeslotWeb.LiveCase, async: false

  import Phoenix.LiveViewTest

  alias TymeslotWeb.ThemeMeetingTestCases

  setup do
    ThemeMeetingTestCases.setup_theme_meeting(%{
      user_name: "Jane Smith",
      theme_id: "1",
      username: "jane",
      color_scheme: "turquoise",
      background_value: "gradient_2",
      start_time: DateTime.add(DateTime.utc_now(), 1, :day),
      duration: 45
    })
  end

  describe "Cancel Confirmed Page" do
    setup %{conn: conn, profile: profile, meeting: meeting} do
      ThemeMeetingTestCases.setup_cancel_confirmed_view(conn, profile, meeting)
    end

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

      # Check meeting details
      formatted_date = Calendar.strftime(meeting.start_time, "%B %d, %Y")
      formatted_time = Calendar.strftime(meeting.start_time, "%-I:%M %p")

      assert render(view) =~ formatted_date
      assert render(view) =~ formatted_time
      assert render(view) =~ "Jane Smith"
      assert render(view) =~ "45 min"
    end

    test "Choose New Time button navigates back to profile", %{
      view: view,
      profile: profile
    } do
      ThemeMeetingTestCases.test_reschedule_page_navigation(
        view,
        "Choose New Time",
        profile.username
      )
    end
  end
end
