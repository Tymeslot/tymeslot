defmodule Tymeslot.DashboardTestHelpers do
  @moduledoc """
  Helper functions for dashboard tests.
  """
  use TymeslotWeb, :verified_routes

  import ExUnit.Assertions, only: [assert: 1]
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn

  alias Ecto.Changeset
  alias Tymeslot.Repo

  @endpoint TymeslotWeb.Endpoint

  @doc """
  Sets up a user with a profile and logs them in.
  """
  @spec setup_dashboard_user(map()) :: {:ok, keyword()}
  def setup_dashboard_user(%{conn: conn}) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)
    conn = conn |> init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, profile: profile}
  end

  @doc """
  Sets up a user with a profile (including theme) and logs them in.
  """
  @spec setup_dashboard_user_with_theme(map(), String.t()) :: {:ok, keyword()}
  def setup_dashboard_user_with_theme(%{conn: conn}, theme_id \\ "1") do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user, booking_theme: theme_id)
    conn = conn |> init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user, profile: profile}
  end

  @doc """
  Logs `user` in, with onboarding marked complete, and opens their Meetings
  page.
  """
  @spec meetings_dashboard(Plug.Conn.t(), struct()) :: Phoenix.LiveViewTest.View.t()
  def meetings_dashboard(conn, user) do
    user
    |> Changeset.change(onboarding_completed_at: DateTime.utc_now(:second))
    |> Repo.update!()

    conn = conn |> init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    view
  end

  @doc "Opens the series modal from `meeting`'s card on the Meetings page."
  @spec open_series_modal(Phoenix.LiveViewTest.View.t(), struct()) ::
          Phoenix.LiveViewTest.View.t()
  def open_series_modal(view, meeting) do
    view |> element("#view-series-#{meeting.id}") |> render_click()
    assert has_element?(view, "#series-modal [data-testid=series-modal]")
    view
  end
end
