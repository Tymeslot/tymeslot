defmodule Tymeslot.ProfilesContextTest do
  @moduledoc """
  Comprehensive behavior tests for the Profiles context module.
  Focuses on user-facing functionality and business rules.
  """

  use Tymeslot.DataCase, async: true

  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  # =====================================
  # Profile Retrieval Behaviors
  # =====================================

  describe "when retrieving a user's profile" do
    test "returns profile when it exists" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      result = Profiles.get_profile(user.id)

      assert result.id == profile.id
      assert result.user_id == user.id
    end

    test "returns nil when profile does not exist" do
      non_existent_user_id = 999_999

      result = Profiles.get_profile(non_existent_user_id)

      assert result == nil
    end
  end

  describe "when getting or creating a profile" do
    test "returns existing profile if it exists" do
      user = insert(:user)
      existing_profile = insert(:profile, user: user)

      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      assert profile.id == existing_profile.id
    end

    test "creates new profile if none exists" do
      user = insert(:user)

      assert {:ok, profile} = Profiles.get_or_create_profile(user.id)

      assert profile.user_id == user.id
      assert profile.timezone == Profiles.get_default_timezone()
    end
  end

  # =====================================
  # Profile Settings Behaviors
  # =====================================

  describe "when viewing profile settings" do
    test "returns configured settings for existing profile" do
      user = insert(:user)

      _profile =
        insert(:profile,
          user: user,
          timezone: "America/Los_Angeles",
          buffer_minutes: 30,
          advance_booking_days: 60,
          min_advance_hours: 6
        )

      settings = Profiles.get_profile_settings(user.id)

      assert settings.timezone == "America/Los_Angeles"
      assert settings.buffer_minutes == 30
      assert settings.advance_booking_days == 60
      assert settings.min_advance_hours == 6
    end

    test "returns default settings when no profile exists" do
      non_existent_user_id = 999_999

      settings = Profiles.get_profile_settings(non_existent_user_id)

      assert settings.timezone == "Europe/Kyiv"
      assert settings.buffer_minutes == 15
      assert settings.advance_booking_days == 90
      assert settings.min_advance_hours == 3
    end
  end

  describe "when updating profile settings" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)
      %{user: user, profile: profile}
    end

    test "updates multiple fields at once", %{profile: profile} do
      attrs = %{
        timezone: "Asia/Tokyo",
        buffer_minutes: 45,
        full_name: "Test User"
      }

      assert {:ok, updated} = Profiles.update_profile(profile, attrs)

      assert updated.timezone == "Asia/Tokyo"
      assert updated.buffer_minutes == 45
      assert updated.full_name == "Test User"
    end

    test "updates single field", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_profile_field(profile, :timezone, "Europe/London")

      assert updated.timezone == "Europe/London"
    end
  end

  # =====================================
  # Timezone Management Behaviors
  # =====================================

  describe "when getting user timezone" do
    test "returns user's configured timezone" do
      user = insert(:user)
      _profile = insert(:profile, user: user, timezone: "Pacific/Auckland")

      timezone = Profiles.get_user_timezone(user.id)

      assert timezone == "Pacific/Auckland"
    end

    test "returns default timezone when no profile exists" do
      non_existent_user_id = 999_999

      timezone = Profiles.get_user_timezone(non_existent_user_id)

      assert timezone == "Europe/Kyiv"
    end
  end

  describe "when updating timezone" do
    test "successfully updates valid timezone" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      assert {:ok, updated} = Profiles.update_timezone(profile, "America/New_York")

      assert updated.timezone == "America/New_York"
    end
  end

  # =====================================
  # Buffer Minutes Behaviors
  # =====================================

  describe "when updating buffer minutes" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)
      %{profile: profile}
    end

    test "accepts valid buffer minutes as integer", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_buffer_minutes(profile, 30)

      assert updated.buffer_minutes == 30
    end

    test "accepts valid buffer minutes as string", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_buffer_minutes(profile, "45")

      assert updated.buffer_minutes == 45
    end

    test "rejects buffer minutes below minimum", %{profile: profile} do
      # Buffer minutes should be non-negative
      result = Profiles.update_buffer_minutes(profile, -1)

      assert {:error, _reason} = result
    end

    test "rejects buffer minutes above maximum", %{profile: profile} do
      # Buffer minutes should not exceed 120
      result = Profiles.update_buffer_minutes(profile, 200)

      assert {:error, :invalid_buffer_minutes} = result
    end

    test "rejects non-numeric string", %{profile: profile} do
      result = Profiles.update_buffer_minutes(profile, "not a number")

      assert {:error, :invalid_buffer_minutes} = result
    end
  end

  # =====================================
  # Advance Booking Days Behaviors
  # =====================================

  describe "when updating advance booking days" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)
      %{profile: profile}
    end

    test "accepts valid days as integer", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_advance_booking_days(profile, 60)

      assert updated.advance_booking_days == 60
    end

    test "accepts valid days as string", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_advance_booking_days(profile, "30")

      assert updated.advance_booking_days == 30
    end

    test "rejects days below minimum", %{profile: profile} do
      result = Profiles.update_advance_booking_days(profile, 0)

      assert {:error, :invalid_advance_booking_days} = result
    end

    test "rejects days above maximum", %{profile: profile} do
      # More than 365 days should be rejected
      result = Profiles.update_advance_booking_days(profile, 400)

      assert {:error, :invalid_advance_booking_days} = result
    end

    test "rejects non-numeric string", %{profile: profile} do
      result = Profiles.update_advance_booking_days(profile, "invalid")

      assert {:error, :invalid_advance_booking_days} = result
    end
  end

  # =====================================
  # Min Advance Hours Behaviors
  # =====================================

  describe "when updating minimum advance hours" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)
      %{profile: profile}
    end

    test "accepts valid hours as integer", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_min_advance_hours(profile, 12)

      assert updated.min_advance_hours == 12
    end

    test "accepts valid hours as string", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_min_advance_hours(profile, "24")

      assert updated.min_advance_hours == 24
    end

    test "accepts zero hours (immediate booking)", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_min_advance_hours(profile, 0)

      assert updated.min_advance_hours == 0
    end

    test "rejects hours above maximum (168 = 7 days)", %{profile: profile} do
      result = Profiles.update_min_advance_hours(profile, 200)

      assert {:error, :invalid_min_advance_hours} = result
    end

    test "rejects negative hours", %{profile: profile} do
      result = Profiles.update_min_advance_hours(profile, "-5")

      assert {:error, :invalid_min_advance_hours} = result
    end
  end

  # =====================================
  # Username Behaviors
  # =====================================

  describe "when generating default username" do
    test "returns base username when available" do
      user = insert(:user)
      base = "user_#{user.id}"

      assert Profiles.generate_default_username(user.id) == base
    end

    test "returns username with random suffix when base is taken" do
      user = insert(:user)
      base = "user_#{user.id}"
      insert(:profile, username: base)

      username = Profiles.generate_default_username(user.id)

      assert String.starts_with?(username, "#{base}_")
      assert String.length(username) == String.length(base) + 1 + 8
      assert Profiles.username_available?(username)
    end
  end

  describe "when checking username availability" do
    test "returns true for available username" do
      result = Profiles.username_available?("available-user-#{System.unique_integer([:positive])}")

      assert result == true
    end

    test "returns false for taken username" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "taken-username")

      result = Profiles.username_available?("taken-username")

      assert result == false
    end
  end

  describe "when validating username format" do
    test "accepts valid lowercase username" do
      result = Profiles.validate_username_format("validuser")

      assert result == :ok
    end

    test "accepts username with numbers" do
      result = Profiles.validate_username_format("user123")

      assert result == :ok
    end

    test "accepts username with hyphens" do
      result = Profiles.validate_username_format("user-name")

      assert result == :ok
    end

    test "accepts username with underscores" do
      result = Profiles.validate_username_format("user_name")

      assert result == :ok
    end

    test "rejects username that is too short" do
      result = Profiles.validate_username_format("ab")

      assert {:error, message} = result
      assert message =~ "at least 3 characters"
    end

    test "rejects username that is too long" do
      long_username = String.duplicate("a", 31)
      result = Profiles.validate_username_format(long_username)

      assert {:error, message} = result
      assert message =~ "at most 30 characters"
    end

    test "rejects username with uppercase letters" do
      result = Profiles.validate_username_format("InvalidUser")

      assert {:error, _message} = result
    end

    test "rejects username starting with hyphen" do
      result = Profiles.validate_username_format("-invalid")

      assert {:error, _message} = result
    end

    test "rejects reserved username" do
      result = Profiles.validate_username_format("admin")

      assert {:error, message} = result
      assert message =~ "reserved"
    end

    test "rejects non-string input" do
      result = Profiles.validate_username_format(123)

      assert {:error, "Username must be a string"} = result
    end
  end

  describe "when updating username" do
    test "successfully updates valid username" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)

      new_username = "newuser#{System.unique_integer([:positive])}"
      result = Profiles.update_username(profile, new_username, user.id)

      assert {:ok, updated} = result
      assert updated.username == new_username
    end

    test "rejects invalid username format" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      result = Profiles.update_username(profile, "IN", user.id)

      assert {:error, _reason} = result
    end

    test "rejects reserved username" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      result = Profiles.update_username(profile, "admin", user.id)

      assert {:error, _reason} = result
    end
  end

  describe "when getting profile by username" do
    test "returns profile when username exists" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "testuser")

      result = Profiles.get_profile_by_username("testuser")

      assert result.id == profile.id
      assert result.username == "testuser"
    end

    test "returns nil when username does not exist" do
      result = Profiles.get_profile_by_username("nonexistent")

      assert result == nil
    end
  end

  # =====================================
  # Organizer Context Behaviors
  # =====================================

  describe "when resolving organizer context" do
    test "returns context for existing profile with username" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "organizer", full_name: "Test Organizer")
      _meeting_type = insert(:meeting_type, user: user)

      result = Profiles.resolve_organizer_context("organizer")

      assert {:ok, context} = result
      assert context.username == "organizer"
      assert context.profile.id == profile.id
      assert context.user_id == user.id
      assert context.page_title =~ "Test Organizer"
    end

    test "returns error for non-existent username" do
      result = Profiles.resolve_organizer_context("nonexistent")

      assert {:error, :profile_not_found} = result
    end
  end

  # =====================================
  # Full Name Behaviors
  # =====================================

  describe "when updating full name" do
    test "successfully updates full name" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      assert {:ok, updated} = Profiles.update_full_name(profile, "John Doe")

      assert updated.full_name == "John Doe"
    end
  end

  describe "when getting display name" do
    test "returns full name when set" do
      user = insert(:user)
      profile = insert(:profile, user: user, full_name: "Jane Doe")

      result = Profiles.display_name(profile)

      assert result == "Jane Doe"
    end

    test "returns nil when full name is empty" do
      user = insert(:user)
      profile = insert(:profile, user: user, full_name: "")

      result = Profiles.display_name(profile)

      assert result == nil
    end

    test "returns nil when full name is whitespace only" do
      user = insert(:user)
      profile = insert(:profile, user: user, full_name: "   ")

      result = Profiles.display_name(profile)

      assert result == nil
    end

    test "returns nil for nil profile" do
      result = Profiles.display_name(nil)

      assert result == nil
    end
  end

  # =====================================
  # Avatar Behaviors
  # =====================================

  describe "when getting avatar URL" do
    test "returns upload path when avatar is set" do
      user = insert(:user)
      profile = insert(:profile, user: user, avatar: "test_avatar.jpg")

      url = Profiles.avatar_url(profile)

      assert url =~ "/uploads/avatars/"
      assert url =~ "test_avatar.jpg"
    end

    test "returns fallback data URI when avatar is not set" do
      user = insert(:user)
      profile = insert(:profile, user: user, avatar: nil)

      url = Profiles.avatar_url(profile)

      # Fallback should be a data URI
      assert url =~ "data:image/svg+xml"
    end

    test "returns fallback for empty avatar string" do
      user = insert(:user)
      profile = insert(:profile, user: user, avatar: "")

      url = Profiles.avatar_url(profile)

      assert url =~ "data:image/svg+xml"
    end

    test "returns fallback for nil profile" do
      url = Profiles.avatar_url(nil)

      assert url =~ "data:image/svg+xml"
    end

    test "preserves absolute paths starting with /" do
      user = insert(:user)
      profile = insert(:profile, user: user, avatar: "/static/default.png")

      url = Profiles.avatar_url(profile)

      assert url == "/static/default.png"
    end
  end

  describe "when getting avatar alt text" do
    test "returns full name when available" do
      user = insert(:user)
      profile = insert(:profile, user: user, full_name: "John Smith")

      alt = Profiles.avatar_alt_text(profile)

      assert alt == "John Smith"
    end

    test "returns email-based text when no full name" do
      user = insert(:user, email: "test@example.com")
      profile = Repo.preload(insert(:profile, user: user, full_name: nil), :user)

      alt = Profiles.avatar_alt_text(profile)

      assert alt =~ "test@example.com"
    end

    test "returns default text for nil profile" do
      alt = Profiles.avatar_alt_text(nil)

      assert alt == "Profile"
    end
  end

  # =====================================
  # Booking Theme Behaviors
  # =====================================

  describe "when updating booking theme" do
    test "accepts valid theme ID" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      # Valid theme IDs are "1" (quill) and "2" (rhythm)
      result = Profiles.update_booking_theme(profile, "1")

      assert {:ok, updated} = result
      assert updated.booking_theme == "1"
    end

    test "rejects invalid theme ID" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      result = Profiles.update_booking_theme(profile, "nonexistent-theme")

      assert {:error, "Invalid theme ID"} = result
    end
  end

  # =====================================
  # Validation Delegate Behaviors
  # =====================================

  describe "validation delegates" do
    test "validate_buffer_minutes returns true for valid values" do
      assert Profiles.validate_buffer_minutes(0) == true
      assert Profiles.validate_buffer_minutes(30) == true
      assert Profiles.validate_buffer_minutes(120) == true
    end

    test "validate_buffer_minutes returns false for invalid values" do
      assert Profiles.validate_buffer_minutes(-1) == false
      assert Profiles.validate_buffer_minutes(121) == false
    end

    test "validate_advance_booking_days returns true for valid values" do
      assert Profiles.validate_advance_booking_days(1) == true
      assert Profiles.validate_advance_booking_days(90) == true
      assert Profiles.validate_advance_booking_days(365) == true
    end

    test "validate_advance_booking_days returns false for invalid values" do
      assert Profiles.validate_advance_booking_days(0) == false
      assert Profiles.validate_advance_booking_days(366) == false
    end

    test "validate_min_advance_hours returns true for valid values" do
      assert Profiles.validate_min_advance_hours(0) == true
      assert Profiles.validate_min_advance_hours(24) == true
      assert Profiles.validate_min_advance_hours(168) == true
    end

    test "validate_min_advance_hours returns false for invalid values" do
      assert Profiles.validate_min_advance_hours(-1) == false
      assert Profiles.validate_min_advance_hours(169) == false
    end
  end
end
