defmodule TymeslotWeb.ThemeMeetingTestCases do
  @moduledoc """
  Shared test logic for theme meeting pages (cancel confirmed, reschedule).
  """
  use TymeslotWeb, :verified_routes

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import ExUnit.Assertions
  import Tymeslot.Factory

  alias Tymeslot.TestMocks

  @doc """
  Sets up a user, profile, theme customization, and meeting for theme tests.
  """
  @spec setup_theme_meeting(map()) :: {:ok, keyword()}
  def setup_theme_meeting(attrs) do
    TestMocks.setup_subscription_mocks()

    user_name = Map.get(attrs, :user_name)
    theme_id = Map.get(attrs, :theme_id)
    username = Map.get(attrs, :username)
    color_scheme = Map.get(attrs, :color_scheme)
    background_value = Map.get(attrs, :background_value)
    start_time = Map.get(attrs, :start_time)
    duration = Map.get(attrs, :duration)

    user = insert(:user, name: user_name)
    profile = insert(:profile, user: user, username: username, booking_theme: theme_id)

    insert(:theme_customization,
      profile: profile,
      theme_id: theme_id,
      color_scheme: color_scheme,
      background_type: "gradient",
      background_value: background_value
    )

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_name: user.name,
        start_time: start_time,
        duration: duration,
        attendee_timezone: "UTC",
        status: "confirmed"
      )

    {:ok, user: user, profile: profile, meeting: meeting}
  end

  @doc """
  Sets up the view for the cancel confirmed page.
  """
  @spec setup_cancel_confirmed_view(Plug.Conn.t(), term(), term()) :: map()
  def setup_cancel_confirmed_view(conn, profile, meeting) do
    {:ok, view, _html} =
      live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/cancel-confirmed")

    %{view: view}
  end

  @doc """
  Sets up the view for the reschedule page.
  """
  @spec setup_reschedule_view(Plug.Conn.t(), term(), term()) :: map()
  def setup_reschedule_view(conn, profile, meeting) do
    {:ok, view, _html} = live(conn, ~p"/#{profile.username}/meeting/#{meeting.uid}/reschedule")
    %{view: view}
  end

  @doc """
  Tests the cancel confirmed page rendering and navigation.
  """
  @spec test_cancel_confirmed_page(term()) :: term()
  def test_cancel_confirmed_page(view) do
    assert render(view) =~ "Meeting Cancelled"
    assert render(view) =~ "Your meeting has been successfully cancelled"
    assert render(view) =~ "Cancellation emails have been sent"

    assert {:error, {redirect_type, %{to: to}}} =
             view
             |> element("button", "Schedule a New Meeting")
             |> render_click()

    assert redirect_type in [:redirect, :live_redirect]
    assert to == "/"
  end

  @doc """
  Tests the reschedule page rendering common elements.
  """
  @spec test_reschedule_page_rendering(term()) :: term()
  def test_reschedule_page_rendering(view) do
    assert render(view) =~ "Reschedule Appointment"
    assert render(view) =~ "Select a new time for your meeting"
  end

  @doc """
  Tests the reschedule page navigation back to profile.
  """
  @spec test_reschedule_page_navigation(term(), String.t(), String.t()) :: term()
  def test_reschedule_page_navigation(view, button_text, profile_username) do
    assert {:error, {redirect_type, %{to: to}}} =
             view
             |> element("button", button_text)
             |> render_click()

    assert redirect_type in [:redirect, :live_redirect]
    assert to == "/#{profile_username}"
  end

  @doc """
  Asserts that meeting details (date, time, organizer, duration) are rendered.
  """
  @spec assert_meeting_details_rendered(term(), term(), String.t(), integer()) :: term()
  def assert_meeting_details_rendered(view, meeting, organizer_name, duration) do
    html = render(view)

    formatted_date = Calendar.strftime(meeting.start_time, "%B %d, %Y")
    formatted_time = Calendar.strftime(meeting.start_time, "%-I:%M %p")

    assert html =~ formatted_date
    assert html =~ formatted_time
    assert html =~ organizer_name
    assert html =~ "#{duration} min"
  end
end
