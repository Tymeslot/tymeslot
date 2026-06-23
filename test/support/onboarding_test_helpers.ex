defmodule TymeslotWeb.OnboardingTestHelpers do
  @moduledoc """
  Helper functions for onboarding tests.
  """

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @endpoint TymeslotWeb.Endpoint

  @doc """
  Helper to fill profile form (basic settings).
  """
  @spec fill_profile(any(), String.t(), String.t()) :: String.t()
  def fill_profile(view, full_name, username) do
    render_change(view, "validate_basic_settings", %{
      "basic_settings" => %{
        "full_name" => full_name,
        "username" => username
      }
    })
  end

  @doc """
  Alias for fill_profile/3 — kept for backward compatibility in tests.
  """
  @spec fill_basic_settings(any(), String.t(), String.t()) :: String.t()
  def fill_basic_settings(view, full_name, username) do
    fill_profile(view, full_name, username)
  end

  @doc """
  Sets up the test session with Phoenix.ConnTest.
  """
  @spec setup_onboarding_session(Plug.Conn.t()) :: Plug.Conn.t()
  def setup_onboarding_session(conn) do
    init_test_session(conn, %{})
  end

  @doc """
  Creates a user, logs them in, and mounts the onboarding LiveView.
  Returns the view, the html, and the user.

  ## Options

    * `:connect_params` - map of connect params passed to the LiveView mount
      (e.g., `%{"timezone" => "Europe/Paris"}`)

  """
  @spec setup_onboarding(Plug.Conn.t(), map(), map() | nil, keyword()) ::
          {:ok, any(), String.t(), any()}
  def setup_onboarding(conn, user_params \\ %{}, profile_params \\ nil, opts \\ []) do
    user = insert(:user, Map.put_new(user_params, :onboarding_completed_at, nil))

    if profile_params do
      insert(:profile, Map.merge(profile_params, %{user: user}))
    end

    conn = log_in_user(conn, user)

    conn =
      case Keyword.get(opts, :connect_params) do
        nil -> conn
        params -> put_connect_params(conn, params)
      end

    {:ok, view, html} = live(conn, "/onboarding")
    {:ok, view, html, user}
  end

  @doc """
  Navigates from the welcome step to the first scheduling preference step (buffer time).
  Fills the profile form and clicks through connect_calendar.
  """
  @spec navigate_to_scheduling_steps(any()) :: any()
  def navigate_to_scheduling_steps(view) do
    # From welcome to profile
    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    # Fill profile form with unique username
    view
    |> form("form#profile-form", %{
      "full_name" => "Test User",
      "username" => "testuser#{System.unique_integer([:positive])}"
    })
    |> render_change()

    # Profile to connect_calendar
    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    # connect_calendar is a forced choice — select "skip" before Continue,
    # otherwise next_step is a no-op on this step.
    view
    |> element(~s{button[phx-value-option="skip"]})
    |> render_click()

    # connect_calendar to buffer_time
    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    view
  end

  @doc """
  Alias for navigate_to_scheduling_steps/1 — kept for backward compatibility.
  """
  @spec navigate_to_preferences(any()) :: any()
  def navigate_to_preferences(view), do: navigate_to_scheduling_steps(view)

  @doc """
  Alias for navigate_to_scheduling_steps/1 — kept for backward compatibility.
  """
  @spec navigate_to_scheduling_preferences(any()) :: any()
  def navigate_to_scheduling_preferences(view), do: navigate_to_scheduling_steps(view)

  @doc """
  Navigates from the welcome step to the booking window step (advance_booking_days).
  """
  @spec navigate_to_booking_window_step(any()) :: any()
  def navigate_to_booking_window_step(view) do
    navigate_to_scheduling_steps(view)

    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    view
  end

  @doc """
  Navigates from the welcome step to the minimum notice step (min_advance_hours).
  """
  @spec navigate_to_minimum_notice_step(any()) :: any()
  def navigate_to_minimum_notice_step(view) do
    navigate_to_booking_window_step(view)

    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    view
  end
end
