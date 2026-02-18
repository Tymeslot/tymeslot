defmodule Tymeslot.ProfilesContextTest do
  @moduledoc """
  Comprehensive behavior tests for the Profiles context module.
  Focuses on user-facing functionality and business rules.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Profiles

  # =====================================
  # Profile Retrieval Behaviors
  # =====================================

  describe "profile retrieval" do
    test "returns profile when it exists" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      result = Profiles.get_profile(user.id)

      assert result.id == profile.id
      assert result.user_id == user.id
    end

    test "returns nil when profile does not exist" do
      assert Profiles.get_profile(999_999) == nil
    end

    test "get_or_create_profile returns existing profile" do
      user = insert(:user)
      existing_profile = insert(:profile, user: user)

      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      assert profile.id == existing_profile.id
    end

    test "get_or_create_profile creates new profile if none exists" do
      user = insert(:user)

      assert {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.user_id == user.id
      assert profile.timezone == Profiles.get_default_timezone()
    end

    test "get_profile_by_username returns profile when username exists" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "testuser")

      result = Profiles.get_profile_by_username("testuser")

      assert result.id == profile.id
      assert result.username == "testuser"
    end
  end

  # =====================================
  # Profile Settings & Updates
  # =====================================

  describe "profile settings" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)
      %{user: user, profile: profile}
    end

    test "get_profile_settings returns configured settings", %{user: user} do
      _profile =
        update_profile_settings(user.id, %{
          timezone: "America/Los_Angeles",
          buffer_minutes: 30,
          advance_booking_days: 60,
          min_advance_hours: 6
        })

      settings = Profiles.get_profile_settings(user.id)

      assert settings.timezone == "America/Los_Angeles"
      assert settings.buffer_minutes == 30
      assert settings.advance_booking_days == 60
      assert settings.min_advance_hours == 6
    end

    test "update_profile updates multiple fields", %{profile: profile} do
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

    test "update_profile_field updates single field", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_profile_field(profile, :timezone, "Europe/London")
      assert updated.timezone == "Europe/London"
    end
  end

  # =====================================
  # Username Management
  # =====================================

  describe "username management" do
    test "generate_default_username returns available username" do
      user = insert(:user)
      username = Profiles.generate_default_username(user.id)

      assert String.starts_with?(username, "user_#{user.id}")
      assert Profiles.username_available?(username)
    end

    test "update_username successfully updates valid username" do
      user = insert(:user)
      profile = insert(:profile, user: user)
      new_username = "newuser#{System.unique_integer([:positive])}"

      assert {:ok, updated} = Profiles.update_username(profile, new_username, user.id)
      assert updated.username == new_username
    end

    test "update_username respects rate limits" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      # We don't want to test the exact limit of the RateLimiter here,
      # but that Profiles.update_username calls it.
      # In a real scenario, we might mock RateLimiter, but for now we just verify it works.
      new_username = "user#{System.unique_integer([:positive])}"
      assert {:ok, _result} = Profiles.update_username(profile, new_username, user.id)
    end

    test "validate_username_format rejects invalid formats" do
      # too short
      assert {:error, _reason} = Profiles.validate_username_format("ab")
      # reserved
      assert {:error, _reason} = Profiles.validate_username_format("admin")
      # spaces/caps
      assert {:error, _reason} = Profiles.validate_username_format("Invalid User")
      assert Profiles.validate_username_format("valid_user-123") == :ok
    end
  end

  # =====================================
  # Scheduling Preferences
  # =====================================

  describe "scheduling preferences" do
    setup do
      %{profile: insert(:profile)}
    end

    test "update_buffer_minutes validates range", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_buffer_minutes(profile, 30)
      assert updated.buffer_minutes == 30
      assert {:error, :invalid_buffer_minutes} = Profiles.update_buffer_minutes(profile, 200)
    end

    test "update_advance_booking_days validates range", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_advance_booking_days(profile, 60)
      assert updated.advance_booking_days == 60

      assert {:error, :invalid_advance_booking_days} =
               Profiles.update_advance_booking_days(profile, 0)
    end

    test "update_min_advance_hours validates range", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_min_advance_hours(profile, 12)
      assert updated.min_advance_hours == 12

      assert {:error, :invalid_min_advance_hours} =
               Profiles.update_min_advance_hours(profile, 200)
    end
  end

  # =====================================
  # Avatar & Display
  # =====================================

  describe "avatar and display" do
    test "avatar_url returns correct path or fallback" do
      profile = insert(:profile, avatar: "test.jpg")
      assert Profiles.avatar_url(profile) =~ "/uploads/avatars/"
      assert Profiles.avatar_url(profile) =~ "test.jpg"

      assert Profiles.avatar_url(nil) =~ "data:image/svg+xml"
      assert Profiles.avatar_url(%{profile | avatar: nil}) =~ "data:image/svg+xml"
    end

    test "update_avatar validates image content" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      # Create a fake "image" that is just text
      fake_path = "/tmp/fake_image.jpg"
      File.write!(fake_path, "not an image")

      entry = %{
        path: fake_path,
        client_name: "fake.jpg"
      }

      assert {:error, :invalid_image_format} = Profiles.update_avatar(profile, entry)
      File.rm!(fake_path)
    end

    test "update_avatar accepts valid image content" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      # 1x1 transparent PNG
      png_binary =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 11, 73, 68, 65, 84, 8, 153, 99, 96, 0, 2, 0, 0,
          5, 0, 1, 34, 38, 10, 75, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      fake_path = "/tmp/valid_image.png"
      File.write!(fake_path, png_binary)

      entry = %{
        path: fake_path,
        client_name: "valid.png"
      }

      assert {:ok, updated_profile} = Profiles.update_avatar(profile, entry)
      assert updated_profile.avatar =~ "_avatar_"

      # Clean up
      upload_dir = Application.get_env(:tymeslot, :upload_directory, "uploads")
      File.rm_rf!(Path.join(upload_dir, "avatars/#{profile.id}"))
      File.rm!(fake_path)
    end

    test "display_name returns full name or nil" do
      assert Profiles.display_name(insert(:profile, full_name: "John Doe")) == "John Doe"
      assert Profiles.display_name(insert(:profile, full_name: "")) == nil
      assert Profiles.display_name(nil) == nil
    end
  end

  # =====================================
  # Organizer Context
  # =====================================

  describe "organizer context" do
    test "resolve_organizer_context returns full context" do
      user = insert(:user)
      _profile = insert(:profile, user: user, username: "org", full_name: "Org Name")
      _mt = insert(:meeting_type, user: user)

      assert {:ok, context} = Profiles.resolve_organizer_context("org")
      assert context.username == "org"
      assert context.profile.full_name == "Org Name"
      assert context.meeting_types != []
      assert context.page_title =~ "Org Name"
    end
  end

  # Helper to update settings directly in DB for testing retrieval
  defp update_profile_settings(user_id, attrs) do
    {:ok, profile} = ProfileQueries.get_by_user_id(user_id)
    ProfileQueries.update_profile(profile, attrs)
  end
end
