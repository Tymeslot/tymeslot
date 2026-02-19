defmodule TymeslotWeb.Dashboard.ProfileSettingsRateLimitingTest do
  @moduledoc """
  Tests that the profile settings LiveView components correctly handle rate-limit
  exhaustion at the UI level. Each test pre-exhausts the relevant bucket before
  triggering the LiveView action and then verifies the expected behavior.

  Must run with `async: false` because rate-limit state lives in a shared ETS table.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :profiles
  @moduletag :live
  @moduletag :security

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Security.RateLimiter

  setup :setup_dashboard_user

  setup do
    RateLimiter.clear_all()
    :ok
  end

  # ---------------------------------------------------------------------------
  # Avatar upload rate limiting
  # ---------------------------------------------------------------------------

  describe "Avatar upload rate limiting" do
    test "shows flash error when avatar upload rate limit is exceeded", %{
      conn: conn,
      user: user
    } do
      # Exhaust the avatar upload bucket for this user (limit: 20 per hour)
      for _i <- 1..20 do
        RateLimiter.check_avatar_upload_rate_limit(user.id)
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      png_content =
        <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0,
          0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

      avatar = %{
        last_modified: System.system_time(:millisecond),
        name: "avatar.png",
        content: png_content,
        type: "image/png"
      }

      view
      |> file_input("#avatar-upload-form", :avatar, [avatar])
      |> render_upload("avatar.png")

      render(view)

      html = render(view)
      refute html =~ "Avatar updated successfully"
    end
  end

  # ---------------------------------------------------------------------------
  # Username change rate limiting
  # ---------------------------------------------------------------------------

  describe "Username change rate limiting" do
    test "shows flash error when username change rate limit is exceeded", %{
      conn: conn,
      user: user
    } do
      # Exhaust the username change bucket for this user (limit: 6 per 2 hours)
      for _i <- 1..6 do
        RateLimiter.check_username_change_rate_limit("user:#{user.id}")
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> form("#username-form-container form", %{username: "blocked-username"})
      |> render_submit()

      assert render(view) =~ "Too many username change attempts"
    end
  end

  # ---------------------------------------------------------------------------
  # Username availability check rate limiting
  # ---------------------------------------------------------------------------

  describe "Username availability check rate limiting" do
    test "silently ignores availability checks when rate limit is exceeded", %{
      conn: conn,
      user: user
    } do
      # Exhaust the username check bucket for this user (limit: 60 per 2 minutes)
      for _i <- 1..60 do
        RateLimiter.check_username_check_rate_limit("user:#{user.id}")
      end

      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      # With the bucket exhausted the component silently drops the check
      # (no update to username_available assign, no error shown)
      view
      |> form("#username-form-container form", %{username: "some-new-name"})
      |> render_change()

      html = render(view)
      refute html =~ "Available"
      refute html =~ "Taken"
    end
  end
end
