defmodule TymeslotWeb.OnboardingTestHelpers do
  @moduledoc """
  Helper functions for onboarding tests.
  """

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  @endpoint TymeslotWeb.Endpoint

  alias ExUnit.Callbacks
  alias Tymeslot.Security.RateLimiter

  @doc """
  Ensures the rate limiter is started for tests.
  """
  @spec ensure_rate_limiter_started() :: :ok
  def ensure_rate_limiter_started do
    case Process.whereis(RateLimiter) do
      nil -> Callbacks.start_supervised!(RateLimiter)
      _pid -> :ok
    end
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
  """
  @spec setup_onboarding(Plug.Conn.t(), map(), map() | nil) :: {:ok, any(), String.t(), any()}
  def setup_onboarding(conn, user_params \\ %{}, profile_params \\ nil) do
    user = insert(:user, Map.put_new(user_params, :onboarding_completed_at, nil))

    if profile_params do
      insert(:profile, Map.merge(profile_params, %{user: user}))
    end

    conn = log_in_user(conn, user)
    {:ok, view, html} = live(conn, "/onboarding")
    {:ok, view, html, user}
  end
end
