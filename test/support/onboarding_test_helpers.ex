defmodule TymeslotWeb.OnboardingTestHelpers do
  @moduledoc """
  Helper functions for onboarding tests.
  """

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @endpoint TymeslotWeb.Endpoint

  alias Tymeslot.Security.RateLimiter

  @doc """
  Ensures the rate limiter is ready for tests.
  RateLimit (Hammer ETS) is always started in the supervision tree.
  """
  @spec ensure_rate_limiter_started() :: :ok
  def ensure_rate_limiter_started do
    RateLimiter.clear_all()
  end

  @doc """
  Helper to fill basic settings form.
  """
  @spec fill_basic_settings(any(), String.t(), String.t()) :: String.t()
  def fill_basic_settings(view, full_name, username) do
    render_change(view, "validate_basic_settings", %{
      "basic_settings" => %{
        "full_name" => full_name,
        "username" => username
      }
    })
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
  Navigates from the current step to the scheduling preferences step.
  Assumes the view is at the welcome step and navigates through basic settings.
  """
  @spec navigate_to_scheduling_preferences(any()) :: any()
  def navigate_to_scheduling_preferences(view) do
    # From welcome to basic settings
    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    # Fill basic settings with unique username
    view
    |> form("form#basic-settings-form", %{
      "full_name" => "Test User",
      "username" => "testuser#{System.unique_integer([:positive])}"
    })
    |> render_change()

    # To scheduling preferences
    view
    |> element("button[phx-click='next_step']")
    |> render_click()

    view
  end
end
