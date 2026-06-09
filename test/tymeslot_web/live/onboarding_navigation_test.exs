defmodule TymeslotWeb.OnboardingNavigationTest do
  @moduledoc """
  Navigation tests for the onboarding flow.

  Tests step transitions, skip functionality, and navigation behavior including:
  - Forward/backward navigation through steps
  - Skip onboarding modal and confirmation
  - Progress indicator display
  - Invalid step handling
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Repo
  alias TymeslotWeb.OnboardingLive.StepConfig

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "forward navigation" do
    test "user can navigate forward through all steps", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Welcome step
      assert has_element?(view, ".onboarding-step-title")

      # Continue to profile
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify profile form is present
      assert has_element?(view, "#profile-form")

      # Fill required fields
      fill_basic_settings(view, "Test User", "testuser123")

      # Continue to connect_calendar
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify calendar step
      assert has_element?(view, ".onboarding-provider-cards")

      # Continue to buffer_time
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify buffer_time step
      assert has_element?(view, "button[phx-value-buffer_minutes]")

      # Continue through booking_window and minimum_notice to ready
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      # Verify ready step
      assert has_element?(view, ".onboarding-step-title")

      assert has_element?(
               view,
               ".onboarding-step-description",
               "Your account is ready. Head to your dashboard to start scheduling."
             )

      assert has_element?(view, "button[phx-click='next_step']", "Go to dashboard")
    end

    test "next button shows correct text on each step", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Welcome — button text is "Let's go"
      assert has_element?(view, "button[phx-click='next_step']")

      # Navigate to profile
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      assert render(view) =~ StepConfig.next_button_text(:profile)

      # Fill profile and navigate to connect_calendar
      fill_basic_settings(view, "Test", "test123")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      assert render(view) =~ StepConfig.next_button_text(:connect_calendar)

      # Navigate to buffer_time
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      assert render(view) =~ StepConfig.next_button_text(:buffer_time)

      # Navigate through booking_window and minimum_notice to ready
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      assert render(view) =~ StepConfig.next_button_text(:ready)
    end
  end

  describe "backward navigation" do
    test "user can navigate backward through steps", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Navigate forward to buffer_time (through profile and connect_calendar)
      view |> element("button[phx-click='next_step']") |> render_click()
      fill_basic_settings(view, "Test", "testuser456")
      view |> element("button[phx-click='next_step']") |> render_click()
      view |> element("button[phx-click='next_step']") |> render_click()

      # Verify buffer_time step
      assert has_element?(view, "button[phx-value-buffer_minutes]")

      # Go back to connect_calendar
      view
      |> element("button[phx-click='previous_step']")
      |> render_click()

      assert has_element?(view, ".onboarding-provider-cards")

      # Go back to profile
      view
      |> element("button[phx-click='previous_step']")
      |> render_click()

      assert has_element?(view, "#profile-form")

      # Go back to welcome
      view
      |> element("button[phx-click='previous_step']")
      |> render_click()

      assert has_element?(view, ".onboarding-step-title")
    end

    test "backward navigation preserves filled form data", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: "Original Name"})

      # Navigate to profile step
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Fill in form
      fill_basic_settings(view, "Changed Name", "changeduser")

      # Navigate to connect_calendar
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Navigate back to profile
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

      # Navigate to profile
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Back button should be present
      assert has_element?(view, "button[phx-click='previous_step']")
    end
  end

  describe "skip onboarding functionality" do
    test "skip_onboarding handler completes onboarding and redirects", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Show skip modal via event
      render_click(view, "show_skip_modal")

      # Modal should be visible
      assert has_element?(view, "#skip-onboarding-modal")

      # Confirm skip
      render_click(view, "skip_onboarding")

      # Should redirect to dashboard
      assert_redirect(view, ~p"/dashboard")

      # Verify onboarding_completed_at is set
      user = Repo.reload!(user)
      assert user.onboarding_completed_at != nil
    end

    test "skip_onboarding works from profile step", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Navigate to profile
      view |> element("button[phx-click='next_step']") |> render_click()

      # Show skip modal and confirm
      render_click(view, "show_skip_modal")
      render_click(view, "skip_onboarding")

      assert_redirect(view, ~p"/dashboard")

      user = Repo.reload!(user)
      assert user.onboarding_completed_at != nil
    end

    test "connect_calendar step has skip link", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Navigate to profile
      view |> element("button[phx-click='next_step']") |> render_click()
      fill_basic_settings(view, "Test", "testuser789")

      # Navigate to connect_calendar
      view |> element("button[phx-click='next_step']") |> render_click()

      # Skip link should be present on calendar step
      assert has_element?(view, "button[phx-click='skip_step']")
    end

    test "skip_step on connect_calendar advances to buffer_time", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Navigate to connect_calendar
      view |> element("button[phx-click='next_step']") |> render_click()
      fill_basic_settings(view, "Test", "testuser789b")
      view |> element("button[phx-click='next_step']") |> render_click()

      # Use skip_step to skip calendar connection
      view |> element("button[phx-click='skip_step']") |> render_click()

      # Should now be at buffer_time
      assert has_element?(view, "button[phx-value-buffer_minutes]")
    end

    test "user can cancel skip modal and continue", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Show skip modal via event
      render_click(view, "show_skip_modal")

      # Modal should be visible
      assert has_element?(view, "#skip-onboarding-modal")

      # Cancel the skip
      render_click(view, "hide_skip_modal")

      # Should still be on welcome
      assert has_element?(view, ".onboarding-step-title")

      # Should still be able to continue normally
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should be on profile step
      assert has_element?(view, "#profile-form")

      # Onboarding should NOT be completed
      user = Repo.reload!(user)
      assert user.onboarding_completed_at == nil
    end
  end

  describe "progress indicator" do
    test "progress indicator shows current and completed steps", %{conn: conn} do
      {:ok, view, html, _user} = setup_onboarding(conn)

      # At welcome step - first dot should be current
      assert html =~ "onboarding-progress-dot--current"

      # Navigate to profile
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      html = render(view)

      # First step should show as completed
      assert html =~ "onboarding-progress-dot--completed"

      # Current step should be current
      assert html =~ "onboarding-progress-dot--current"
    end

    test "progress indicator updates when navigating backward", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Navigate forward to connect_calendar
      view |> element("button[phx-click='next_step']") |> render_click()
      fill_basic_settings(view, "Test", "testuser234")
      view |> element("button[phx-click='next_step']") |> render_click()

      # Now at connect_calendar, go back
      view
      |> element("button[phx-click='previous_step']")
      |> render_click()

      html = render(view)

      # First step should still be completed
      assert html =~ "onboarding-progress-dot--completed"
      # Current step (profile) should be current
      assert html =~ "onboarding-progress-dot--current"
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
      assert has_element?(view, ".onboarding-step-title")
    end

    test "direct navigation to valid step works", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)
      conn = log_in_user(conn, user)

      # Navigate directly to profile step
      {:ok, view, _html} = live(conn, ~p"/onboarding?step=profile")

      assert has_element?(view, "#profile-form")
    end
  end
end
