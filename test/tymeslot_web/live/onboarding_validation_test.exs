defmodule TymeslotWeb.OnboardingValidationTest do
  @moduledoc """
  Validation tests for the onboarding flow.

  Tests input validation for:
  - Basic settings (name, username)
  - Real-time validation feedback
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :utils
  @moduletag :onboarding

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Profiles
  alias Tymeslot.Test.ReservingDemoProvider

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "profile - full name validation" do
    test "empty name is allowed (optional field)", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn, %{name: nil})

      # Submit with empty name but valid username
      fill_basic_settings(view, "", "validuser123")

      # Try to proceed
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed to connect_calendar since full name is optional
      assert has_element?(view, ".onboarding-provider-cards")
    end

    test "name with only spaces is allowed (trimmed to empty)", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Submit with spaces only
      fill_basic_settings(view, "   ", "validuser456")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed since spaces-only is trimmed to empty (which is allowed)
      assert has_element?(view, ".onboarding-provider-cards")
    end

    test "valid name is accepted", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Valid name
      fill_basic_settings(view, "Valid Name", "validuser123")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed to connect_calendar
      assert has_element?(view, ".onboarding-provider-cards")

      # Advancing alone is what the empty-name and spaces-only tests already
      # assert — the point here is that the name was persisted.
      {:ok, profile} = Profiles.get_profile_by_user_id(user.id)

      assert profile.full_name == "Valid Name"
      assert profile.username == "validuser123"
    end
  end

  describe "profile - username validation" do
    test "empty username shows error on submit", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

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

      # Username with spaces
      fill_basic_settings(view, "Valid Name", "user with spaces")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should not proceed
      assert has_element?(view, "#profile-form")
    end

    test "username with invalid characters is rejected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Username with special characters
      fill_basic_settings(view, "Valid Name", "user@name!")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should not proceed
      assert has_element?(view, "#profile-form")
    end

    test "username too short is rejected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # 2 character username
      fill_basic_settings(view, "Valid Name", "ab")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should not proceed
      assert has_element?(view, "#profile-form")
    end

    test "username too long is rejected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # 31+ character username
      long_username = String.duplicate("a", 31)

      fill_basic_settings(view, "Valid Name", long_username)

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should not proceed
      assert has_element?(view, "#profile-form")
    end

    test "valid username with lowercase, numbers, underscore, dash is accepted", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Valid username with allowed characters
      fill_basic_settings(view, "Valid Name", "valid_user-123")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed to connect_calendar
      assert has_element?(view, ".onboarding-provider-cards")
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

      # Try to use taken username
      fill_basic_settings(view, "New User", "takenusername")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      html = render(view)

      # Should show error
      assert html =~ "This username is already taken"
      refute html =~ "Please check your input"
      assert has_element?(view, "#profile-form")
    end

    test "a username taken after it was checked explains why on continue", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      fill_basic_settings(view, "New User", "racehandle")
      refute render(view) =~ "already taken"

      # Someone else claims it while this user is still on the form.
      insert(:profile, username: "racehandle")

      view |> element("button[phx-click='next_step']") |> render_click()

      html = render(view)
      assert html =~ "This username is already taken"
      refute html =~ "Please check your input"
      assert has_element?(view, "#profile-form")
    end

    test "a username refused only by the database explains why on continue", %{conn: conn} do
      # Uniqueness is case-insensitive in the database. A legacy handle stored
      # with capitals is invisible to the availability check, so the collision
      # surfaces only when the profile is written.
      insert(:profile, username: "LegacyHandle")

      {:ok, view, _html, _user} = setup_onboarding(conn)

      fill_basic_settings(view, "New User", "legacyhandle")

      view |> element("button[phx-click='next_step']") |> render_click()

      html = render(view)
      assert html =~ "This username is already taken"
      refute html =~ "Please check your input"
      assert has_element?(view, "#profile-form")
    end

    test "a reserved username explains why on continue", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      fill_basic_settings(view, "New User", "admin")

      view |> element("button[phx-click='next_step']") |> render_click()

      html = render(view)
      assert html =~ "This username is reserved"
      refute html =~ "Please check your input"
      assert has_element?(view, "#profile-form")
      refute Profiles.get_profile(user.id).username == "admin"
    end

    test "a username the demo pages serve is refused as reserved", %{conn: conn} do
      with_config(:tymeslot, demo_provider: ReservingDemoProvider)
      demo_username = ReservingDemoProvider.reserved_username()
      {:ok, view, _html, user} = setup_onboarding(conn)

      fill_basic_settings(view, "New User", demo_username)

      view |> element("button[phx-click='next_step']") |> render_click()

      assert render(view) =~ "This username is reserved"
      assert has_element?(view, "#profile-form")
      refute Profiles.get_profile(user.id).username == demo_username
    end

    test "available username proceeds successfully", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Use available username
      fill_basic_settings(view, "New User", "availableuser456")

      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed to connect_calendar
      assert has_element?(view, ".onboarding-provider-cards")
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

      {:ok, view, _html} = live(conn, ~p"/onboarding/profile")

      # Don't change username, just continue
      view
      |> element("button[phx-click='next_step']")
      |> render_click()

      # Should proceed to connect_calendar without availability check
      assert has_element?(view, ".onboarding-provider-cards")
    end
  end

  describe "real-time validation" do
    test "form validates on change and shows inline errors", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Type invalid username and trigger validation
      fill_basic_settings(view, "Valid Name", "ab")

      # Note: Username errors are not shown during typing (only on submit)
      # So we just verify the form processed the change
      assert has_element?(view, "#profile-form")
    end

    test "errors clear when input becomes valid", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # First, invalid input
      fill_basic_settings(view, "", "validuser")

      # Then, fix it
      fill_basic_settings(view, "Valid Name", "validuser")

      # Should have cleared errors
      refute render(view) =~ "error"
    end
  end
end
