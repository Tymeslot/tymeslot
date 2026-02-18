defmodule TymeslotWeb.OnboardingNavigationTest do
  @moduletag :utils
  @moduledoc """
  @moduletag :utils
  Navigation tests for the onboarding flow.

  Tests step transitions, skip functionality, and navigation behavior including:
  - Forward/backward navigation through steps
  - Skip onboarding modal and confirmation
  - Progress indicator display
  - Invalid step handling
  """

  use TymeslotWeb.LiveCase, async: false

  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.OnboardingLive.StepConfig

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    ensure_rate_limiter_started()
    RateLimiter.clear_all()
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "forward navigation" do
    test "user can navigate forward through all steps", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Welcome step - verify we're here using CSS class
      assert has_element?(view, ".onboarding-title")

      # Continue to basic_settings
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify basic settings form is present
      assert has_element?(view, "#basic-settings-form")

      # Fill required fields for basic settings
      fill_basic_settings(view, "Test User", "testuser123")

      # Continue to scheduling_preferences
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify preferences step using specific elements
      assert has_element?(view, "button[phx-value-buffer_minutes]")

      # Continue to complete
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify completion step - check for elements unique to complete step
      assert has_element?(view, ".onboarding-title")
      assert has_element?(view, "button[phx-click='next_step']", "Get Started")
    end

    test "next button shows correct text on each step", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Welcome - should match StepConfig
      assert render(view) =~ StepConfig.next_button_text(:welcome)

      # Navigate to basic_settings
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      assert render(view) =~ StepConfig.next_button_text(:basic_settings)

      # Fill basic settings and navigate
      fill_basic_settings(view, "Test", "test123")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Scheduling preferences
      assert render(view) =~ StepConfig.next_button_text(:scheduling_preferences)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Complete
      assert render(view) =~ StepConfig.next_button_text(:complete)
    end
  end

  describe "backward navigation" do
    test "user can navigate backward through steps", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Navigate forward to scheduling_preferences
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      fill_basic_settings(view, "Test", "testuser456")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify preferences step
      assert has_element?(view, "button[phx-value-buffer_minutes]")

      # Go back to basic_settings
      view
      |> element("button[phx-click='previous_step']")
      |> render_click()

      # Verify form is back
      assert has_element?(view, "#basic-settings-form")

      # Go back to welcome
      view
      |> element("button[phx-click='previous_step']")
      |> render_click()

      # Verify welcome step
      assert has_element?(view, ".onboarding-title")
    end

    test "backward navigation preserves filled form data", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: "Original Name"})

      # Navigate to basic settings
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Fill in form
      fill_basic_settings(view, "Changed Name", "changeduser")

      # Navigate to scheduling preferences
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Navigate back to basic settings
      view
      |> element("button[phx-click='previous_step']")
      |> render_click()

      html = render(view)

      # Form data should still be there
      assert html =~ "changeduser"
    end

    test "no previous button on welcome step", %{conn: conn} do
      {:ok, _view, html, _user} = setup_onboarding(conn)

      # Should not have a Back button on welcome step
      refute html =~ "Back"
    end

    test "previous button appears on later steps", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Navigate to basic_settings
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Back button should be present
      assert has_element?(view, "button[phx-click='previous_step']")
    end
  end

  describe "skip onboarding functionality" do
    test "user can skip onboarding from welcome step", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Click "Skip setup"
      view
      |> element("button[phx-click='show_skip_modal']")
      |> render_click()

      # Modal should be visible
      assert has_element?(view, "#skip-onboarding-modal")

      # Confirm skip
      view
      |> element("button[phx-click='skip_onboarding']")
      |> render_click()

      # Should redirect to dashboard
      assert_redirect(view, ~p"/dashboard")

      # Verify onboarding_completed_at is set
      user = Repo.reload!(user)
      assert user.onboarding_completed_at != nil
    end

    test "user can skip onboarding from basic_settings step", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Navigate to basic_settings
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Click "Skip setup"
      view
      |> element("button[phx-click='show_skip_modal']")
      |> render_click()

      # Confirm skip
      view
      |> element("button[phx-click='skip_onboarding']")
      |> render_click()

      # Should redirect to dashboard
      assert_redirect(view, ~p"/dashboard")

      # Onboarding should be marked complete
      user = Repo.reload!(user)
      assert user.onboarding_completed_at != nil
    end

    test "user can skip onboarding from scheduling_preferences step", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Navigate to basic_settings
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Fill and proceed
      fill_basic_settings(view, "Test", "testuser789")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Now at scheduling_preferences, skip
      view
      |> element("button[phx-click='show_skip_modal']")
      |> render_click()

      view
      |> element("button[phx-click='skip_onboarding']")
      |> render_click()

      # Should redirect to dashboard
      assert_redirect(view, ~p"/dashboard")

      user = Repo.reload!(user)
      assert user.onboarding_completed_at != nil
    end

    test "user can cancel skip modal and continue", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Click "Skip setup"
      view
      |> element("button[phx-click='show_skip_modal']")
      |> render_click()

      # Modal should be visible
      assert has_element?(view, "#skip-onboarding-modal")

      # Click "Continue Setup" to cancel
      view
      |> element("button[phx-click='hide_skip_modal']")
      |> render_click()

      # Should still be on welcome
      assert has_element?(view, ".onboarding-title")

      # Should still be able to continue normally
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should be on basic settings
      assert has_element?(view, "#basic-settings-form")

      # Onboarding should NOT be completed
      user = Repo.reload!(user)
      assert user.onboarding_completed_at == nil
    end
  end

  describe "progress indicator" do
    test "progress indicator shows current and completed steps", %{conn: conn} do
      {:ok, view, html, _user} = setup_onboarding(conn)

      # At welcome step - first circle should be active
      assert html =~ "progress-step-circle--active"

      # Navigate to basic_settings
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      html = render(view)

      # First step should show as completed (checkmark)
      assert html =~ "progress-step-circle--completed"

      # Current step should be active
      assert html =~ "progress-step-circle--active"
    end

    test "progress indicator updates when navigating backward", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Navigate forward twice
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      fill_basic_settings(view, "Test", "testuser234")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Now at scheduling_preferences, go back
      view
      |> element("button[phx-click='previous_step']")
      |> render_click()

      html = render(view)

      # First step should still be completed
      assert html =~ "progress-step-circle--completed"
      # Current step (basic_settings) should be active
      assert html =~ "progress-step-circle--active"
    end
  end

  describe "invalid step handling" do
    test "invalid step name redirects to welcome", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      conn = log_in_user(conn, user)

      # Try to access invalid step
      {:error, {:redirect, redirect_info}} = live(conn, ~p"/onboarding?step=invalid_step")

      # Should redirect to onboarding welcome
      assert %{to: "/onboarding"} = redirect_info
    end

    test "empty step parameter shows welcome", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/onboarding")

      # Should show welcome step
      assert has_element?(view, ".onboarding-title")
    end

    test "direct navigation to valid step works", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      conn = log_in_user(conn, user)

      # Navigate directly to basic_settings
      {:ok, view, _html} = live(conn, ~p"/onboarding?step=basic_settings")

      assert has_element?(view, "#basic-settings-form")
    end
  end
end
