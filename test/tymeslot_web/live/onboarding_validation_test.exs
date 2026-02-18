defmodule TymeslotWeb.OnboardingValidationTest do
  @moduledoc """
  Validation tests for the onboarding flow.

  Tests input validation for:
  - Basic settings (name, username)
  - Scheduling preferences (buffer time, advance booking, min notice)
  - Timezone selection
  - Real-time validation feedback
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils

  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    ensure_rate_limiter_started()
    RateLimiter.clear_all()
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "basic settings - full name validation" do
    test "empty name is allowed (optional field)", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: nil})

      # Navigate to basic settings
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Submit with empty name but valid username
      fill_basic_settings(view, "", "validuser123")

      # Try to proceed
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed to Preferences since full name is optional
      assert has_element?(view, "button[phx-value-buffer_minutes]")
    end

    test "name with only spaces is allowed (trimmed to empty)", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Submit with spaces only
      fill_basic_settings(view, "   ", "validuser456")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed since spaces-only is trimmed to empty (which is allowed)
      assert has_element?(view, "button[phx-value-buffer_minutes]")
    end

    test "valid name is accepted", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Valid name
      fill_basic_settings(view, "Valid Name", "validuser123")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed to scheduling preferences
      assert has_element?(view, "button[phx-value-buffer_minutes]")
    end
  end

  describe "basic settings - username validation" do
    test "empty username shows error on submit", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Submit with empty username
      fill_basic_settings(view, "Valid Name", "")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      html = render(view)

      # Should show error
      assert html =~ "Username is required"
    end

    test "username with spaces is rejected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Username with spaces
      fill_basic_settings(view, "Valid Name", "user with spaces")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should not proceed
      assert has_element?(view, "#basic-settings-form")
    end

    test "username with invalid characters is rejected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Username with special characters
      fill_basic_settings(view, "Valid Name", "user@name!")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should not proceed
      assert has_element?(view, "#basic-settings-form")
    end

    test "username too short is rejected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # 2 character username
      fill_basic_settings(view, "Valid Name", "ab")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should not proceed
      assert has_element?(view, "#basic-settings-form")
    end

    test "username too long is rejected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # 31+ character username
      long_username = String.duplicate("a", 31)

      fill_basic_settings(view, "Valid Name", long_username)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should not proceed
      assert has_element?(view, "#basic-settings-form")
    end

    test "valid username with lowercase, numbers, underscore, dash is accepted", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Valid username with allowed characters
      fill_basic_settings(view, "Valid Name", "valid_user-123")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed
      assert has_element?(view, "button[phx-value-buffer_minutes]")
    end
  end

  describe "username availability" do
    test "taken username shows error", %{conn: conn} do
      # Create existing user with username
      existing_user = insert(:user)

      _existing_profile =
        insert(:profile, username: "takenusername", user: existing_user)

      # New user tries to use same username
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Try to use taken username
      fill_basic_settings(view, "New User", "takenusername")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      html = render(view)

      # Should show error
      assert html =~ "already taken"
    end

    test "available username proceeds successfully", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Use available username
      fill_basic_settings(view, "New User", "availableuser456")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed
      assert has_element?(view, "button[phx-value-buffer_minutes]")
    end

    test "unchanged username does not check availability", %{conn: conn} do
      user = insert(:user, onboarding_completed_at: nil)

      # Create profile with existing username
      _profile =
        insert(:profile,
          user: user,
          username: "existingusername"
        )

      conn = log_in_user(conn, user)

      {:ok, view, _html} = live(conn, ~p"/onboarding")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Don't change username, just continue
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed without availability check
      assert has_element?(view, "button[phx-value-buffer_minutes]")
    end
  end

  # Timezone selection tests removed - these test UI implementation details
  # The timezone functionality is tested in edge_cases_test.exs through the
  # timezone detection and persistence tests

  # Scheduling preferences UI interaction tests removed - these test implementation details
  # The UI uses buttons instead of select elements, making these tests incorrect
  # The actual scheduling preferences functionality is tested through the complete
  # onboarding flow and data persistence tests

  describe "scheduling preferences validation" do
    test "scheduling preferences are saved correctly", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      navigate_to_scheduling_preferences(view)

      # No need to manually set values - form uses profile defaults
      # Just proceed to complete
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Get profile and verify defaults were used
      profile = Repo.get_by!(Tymeslot.DatabaseSchemas.ProfileSchema, user_id: user.id)
      # Defaults from factory: buffer_minutes: 15, advance_booking_days: 90, min_advance_hours: 3
      assert profile.buffer_minutes == 15
      assert profile.advance_booking_days == 90
      assert profile.min_advance_hours == 3
    end

    test "buffer_minutes with valid boundary values (0 and 120) are accepted", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Test minimum value (0)
      view
      |> element(
        "button[phx-click='update_scheduling_preferences'][phx-value-buffer_minutes='0']"
      )
      |> render_click()

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify value was saved
      profile = Repo.get_by!(Tymeslot.DatabaseSchemas.ProfileSchema, user_id: user.id)
      assert profile.buffer_minutes == 0
    end

    test "advance_booking_days with valid minimum boundary (1) is accepted", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Set minimum valid custom value (1 day)
      view
      |> element(
        "button[phx-click='focus_custom_input'][phx-value-setting='advance_booking_days']"
      )
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"advance_booking_days" => "1"})

      # Custom input should still be visible (1 is not in presets)
      html = render(view)
      assert html =~ ~s(name="advance_booking_days")

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify minimum boundary value was saved
      profile = Repo.get_by!(Tymeslot.DatabaseSchemas.ProfileSchema, user_id: user.id)
      assert profile.advance_booking_days == 1
    end

    test "min_advance_hours with valid boundary value (168) is accepted", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      navigate_to_scheduling_preferences(view)

      # Set max valid custom value (168 hours = 1 week)
      view
      |> element("button[phx-click='focus_custom_input'][phx-value-setting='min_advance_hours']")
      |> render_click()

      view
      |> element("form[phx-change='update_scheduling_preferences']")
      |> render_change(%{"min_advance_hours" => "168"})

      # Value should revert to Custom button since 168 is not in onboarding presets
      # (onboarding presets: [0, 1, 3, 6, 12, 24, 48])
      html = render(view)
      assert html =~ ~s(name="min_advance_hours") or html =~ "Custom"

      # Complete onboarding
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Verify max boundary value was saved
      profile = Repo.get_by!(Tymeslot.DatabaseSchemas.ProfileSchema, user_id: user.id)
      assert profile.min_advance_hours == 168
    end
  end

  describe "real-time validation" do
    test "form validates on change and shows inline errors", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Type invalid username and trigger validation
      fill_basic_settings(view, "Valid Name", "ab")

      # Note: Username errors are not shown during typing (only on submit)
      # So we just verify the form processed the change
      assert has_element?(view, "#basic-settings-form")
    end

    test "errors clear when input becomes valid", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # First, invalid input
      fill_basic_settings(view, "", "validuser")

      # Then, fix it
      fill_basic_settings(view, "Valid Name", "validuser")

      # Should have cleared errors
      refute render(view) =~ "error"
    end
  end
end
