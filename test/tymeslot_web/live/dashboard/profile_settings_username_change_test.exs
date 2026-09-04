defmodule TymeslotWeb.Dashboard.ProfileSettingsUsernameChangeTest do
  @moduledoc """
  Replacing a live username breaks every link already shared — the booking
  page, open polls, and the links inside emails this product has already sent —
  with no alias, redirect or history behind it. The organiser must be told what
  they are about to break and must confirm before anything is written.

  Setting a username for the first time breaks nothing and must not be
  interrupted.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :profiles
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  defp with_username(profile, username) do
    {:ok, profile} = ProfileQueries.update_username(profile, username)
    profile
  end

  defp current_username(profile) do
    {:ok, reloaded} = ProfileQueries.get_by_user_id(profile.user_id)
    reloaded.username
  end

  defp submit_username(view, username) do
    view
    |> form("#username-form-container form", %{username: username})
    |> render_submit()
  end

  describe "replacing a username that is already live" do
    setup %{profile: profile} do
      %{profile: with_username(profile, "sarah")}
    end

    test "asks for confirmation and names what breaks, before writing anything",
         %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      html = submit_username(view, "sarah-r")

      assert html =~ "Change your URL to sarah-r?"
      assert html =~ "booking page and every event link"
      assert html =~ "already sent"

      # Nothing is written until the organiser confirms.
      assert current_username(profile) == "sarah"
    end

    test "counts the polls still waiting on votes among the casualties",
         %{conn: conn, user: user} do
      insert(:poll, user: user, status: :open)
      insert(:poll, user: user, status: :open)
      insert(:poll, user: user, status: :confirmed)

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      html = submit_username(view, "sarah-r")

      # The confirmed poll is nobody's live invitation any more.
      assert html =~ "2 polls still waiting on votes"
    end

    test "cancelling leaves the username untouched", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      submit_username(view, "sarah-r")

      html =
        view
        |> element("#username-change-modal button", "Cancel")
        |> render_click()

      refute html =~ "Change your URL to"
      assert current_username(profile) == "sarah"
    end

    test "confirming performs the change", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      submit_username(view, "sarah-r")

      view
      |> element("#username-change-modal button", "Change URL")
      |> render_click()

      assert current_username(profile) == "sarah-r"
    end

    test "still enforces the change rate limit at the point of confirmation",
         %{conn: conn, user: user, profile: profile} do
      # The confirmation step must not become a way around the limit: the
      # modal is a warning, not an authorisation.
      for _attempt <- 1..6 do
        RateLimiter.check_username_change_rate_limit("user:#{user.id}")
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      submit_username(view, "sarah-r")

      view
      |> element("#username-change-modal button", "Change URL")
      |> render_click()

      assert render(view) =~ "Too many username change attempts"
      assert current_username(profile) == "sarah"
    end
  end

  describe "setting a username for the first time" do
    test "saves immediately without a confirmation step", %{conn: conn, profile: profile} do
      assert is_nil(profile.username)

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      html = submit_username(view, "sarah")

      refute html =~ "Change your URL to"
      assert current_username(profile) == "sarah"
    end

    test "re-submitting the same username does not warn about breaking links",
         %{conn: conn, profile: profile} do
      profile = with_username(profile, "sarah")

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      html = submit_username(view, "sarah")

      refute html =~ "Change your URL to"
      assert current_username(profile) == "sarah"
    end
  end
end
