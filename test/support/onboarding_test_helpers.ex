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
  Returns a `{conn, user}` for a fresh, not-yet-onboarded user logged in but
  WITHOUT mounting the LiveView — for tests that drive `live/2` to a specific
  onboarding URL themselves.
  """
  @spec onboarding_conn(Plug.Conn.t()) :: {Plug.Conn.t(), any()}
  def onboarding_conn(conn) do
    user = insert(:user, onboarding_completed_at: nil)
    {log_in_user(conn, user), user}
  end

  @doc """
  Like `setup_onboarding/1` but with an active, bookable calendar integration
  already connected, so the host can go past the calendar step.

  Returns `{:ok, view, html, user}`.
  """
  @spec setup_onboarding_with_calendar(Plug.Conn.t()) :: {:ok, any(), String.t(), any()}
  def setup_onboarding_with_calendar(conn) do
    user = insert(:user, onboarding_completed_at: nil)
    insert(:calendar_integration, user: user)
    conn = log_in_user(conn, user)
    {:ok, view, html} = live(conn, "/onboarding")
    {:ok, view, html, user}
  end

  @doc """
  Advances from the profile step to the `connect_calendar` step, saving the
  profile with a unique, available username.
  """
  @spec navigate_to_calendar_step(any()) :: any()
  def navigate_to_calendar_step(view) do
    fill_profile(view, "Test User", "testuser#{System.unique_integer([:positive])}")
    click_continue(view)
  end

  @doc """
  Advances from the profile step to the `meeting` step. Requires a connected
  calendar (use `setup_onboarding_with_calendar/1`).
  """
  @spec navigate_to_meeting_step(any()) :: any()
  def navigate_to_meeting_step(view) do
    view |> navigate_to_calendar_step() |> click_continue()
  end

  @doc """
  Advances from the profile step to the `choose_theme` step. Requires a
  connected calendar (use `setup_onboarding_with_calendar/1`).
  """
  @spec navigate_to_theme_step(any()) :: any()
  def navigate_to_theme_step(view) do
    view |> navigate_to_meeting_step() |> click_continue()
  end

  @doc """
  Advances from the profile step to the `ready` step. Requires a connected
  calendar (use `setup_onboarding_with_calendar/1`).
  """
  @spec navigate_to_ready_step(any()) :: any()
  def navigate_to_ready_step(view) do
    view |> navigate_to_theme_step() |> click_continue()
  end

  @doc """
  Presses the layout's Continue button.
  """
  @spec click_continue(any()) :: any()
  def click_continue(view) do
    view |> element("button[phx-click='next_step']") |> render_click()
    view
  end

  @doc """
  Selects the CalDAV option and presses Continue — the only way to reach the
  inline credential form under the forced-choice model.
  """
  @spec open_caldav_form(any()) :: any()
  def open_caldav_form(view) do
    view |> element(~s{button[phx-value-option="caldav"]}) |> render_click()
    view |> element("button[phx-click='next_step']") |> render_click()
    view
  end
end
