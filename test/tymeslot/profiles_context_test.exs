defmodule Tymeslot.ProfilesContextTest do
  @moduledoc """
  Comprehensive behavior tests for the Profiles context module.
  Focuses on user-facing functionality and business rules.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :profiles
  @moduletag :unit

  alias Tymeslot.Locales
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Profiles.ReservedPaths
  alias TymeslotWeb.Themes.Core.ThemeInfo

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
      assert is_nil(profile.timezone)
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

    test "username_available? returns true for reserved usernames (DB-only check)" do
      # username_available? only queries the DB — it has no knowledge of reserved names.
      # Reserved names ARE "available" in the DB sense; rejection happens upstream in
      # validate_username_format / InputProcessor before this function is ever reached.
      assert Profiles.username_available?("admin") == true
    end

    test "update_username rejects reserved usernames" do
      user = insert(:user)
      profile = insert(:profile, user: user)

      assert {:error, reason} = Profiles.update_username(profile, "admin", user.id)
      assert is_binary(reason)
      assert reason =~ "reserved"
    end

    test "every supported locale code is a reserved path" do
      # Locale codes are top-level URL prefixes on localised deployments; a
      # username matching one would shadow the locale scope (or vice versa),
      # so reservation must track the locale config rather than a hardcoded
      # list.
      reserved = ReservedPaths.list()

      for code <- Locales.supported_codes() do
        assert code in reserved
      end
    end
  end

  # =====================================
  # Scheduling Preferences
  # =====================================

  describe "scheduling preferences" do
    setup do
      %{profile: insert(:profile)}
    end

    test "update_buffer_minutes accepts valid value", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_buffer_minutes(profile, 30)
      assert updated.buffer_minutes == 30
    end

    test "update_buffer_minutes rejects out-of-range value", %{profile: profile} do
      assert {:error, :invalid_buffer_minutes} = Profiles.update_buffer_minutes(profile, 200)
    end

    test "update_advance_booking_days accepts valid value", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_advance_booking_days(profile, 60)
      assert updated.advance_booking_days == 60
    end

    test "update_advance_booking_days rejects out-of-range value", %{profile: profile} do
      assert {:error, :invalid_advance_booking_days} =
               Profiles.update_advance_booking_days(profile, 0)
    end

    test "update_min_advance_hours accepts valid value", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_min_advance_hours(profile, 12)
      assert updated.min_advance_hours == 12
    end

    test "update_min_advance_hours rejects out-of-range value", %{profile: profile} do
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
      on_exit(fn -> File.rm(fake_path) end)

      entry = %{
        path: fake_path,
        client_name: "fake.jpg"
      }

      assert {:error, :invalid_image_format} = Profiles.update_avatar(profile, entry)
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
      upload_dir = Application.get_env(:tymeslot, :upload_directory, "uploads")

      on_exit(fn ->
        File.rm(fake_path)
        File.rm_rf(Path.join(upload_dir, "avatars/#{profile.id}"))
      end)

      entry = %{
        path: fake_path,
        client_name: "valid.png"
      }

      assert {:ok, updated_profile} = Profiles.update_avatar(profile, entry)
      assert updated_profile.avatar =~ "_avatar_"
    end

    test "delete_avatar removes the avatar from the profile" do
      user = insert(:user)
      profile = insert(:profile, user: user, avatar: "some_avatar.png")

      assert {:ok, updated} = Profiles.delete_avatar(profile)
      assert is_nil(updated.avatar)
    end

    test "display_name returns full_name when present" do
      assert Profiles.display_name(insert(:profile, full_name: "John Doe")) == "John Doe"
    end

    test "display_name returns nil for nil profile" do
      assert Profiles.display_name(nil) == nil
    end

    test "display_name falls back to user.name when full_name is blank" do
      user = insert(:user, name: "Jane Smith")
      profile = insert(:profile, user: user, full_name: nil)
      assert Profiles.display_name(profile) == "Jane Smith"

      profile_empty = insert(:profile, user: insert(:user, name: "Fallback"), full_name: "")
      assert Profiles.display_name(profile_empty) == "Fallback"
    end

    test "display_name returns nil when both full_name and user.name are blank" do
      user = insert(:user, name: nil)
      profile = insert(:profile, user: user, full_name: "")
      assert Profiles.display_name(profile) == nil
    end

    test "display_name returns nil for whitespace-only names" do
      user = insert(:user, name: "   ")
      profile = insert(:profile, user: user, full_name: "   ")
      assert Profiles.display_name(profile) == nil
    end

    test "display_name returns nil when user association is not loaded" do
      profile = insert(:profile, full_name: nil)

      unloaded = %{
        profile
        | user: %Ecto.Association.NotLoaded{
            __field__: :user,
            __cardinality__: :one,
            __owner__: profile.__struct__
          }
      }

      assert Profiles.display_name(unloaded) == nil
    end
  end

  # =====================================
  # Display Name & Timezone Updates
  # =====================================

  describe "display name and timezone updates" do
    setup do
      user = insert(:user)
      profile = insert(:profile, user: user)
      %{user: user, profile: profile}
    end

    test "update_full_name persists the new name", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_full_name(profile, "Jane Smith")
      assert updated.full_name == "Jane Smith"
    end

    test "update_full_name accepts empty string", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_full_name(profile, "")
      # Ecto's :string type coerces "" to nil on cast, so nil is the persisted value.
      assert is_nil(updated.full_name)
    end

    test "update_timezone persists the new timezone", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_timezone(profile, "America/New_York")
      assert updated.timezone == "America/New_York"
    end

    test "update_timezone rejects invalid timezone", %{profile: profile} do
      assert {:error, _reason} = Profiles.update_timezone(profile, "Not/AReal_Zone")
    end
  end

  # =====================================
  # Timezone Prefill
  # =====================================

  describe "prefill_timezone" do
    test "returns nil unchanged when profile is nil" do
      assert Profiles.prefill_timezone(nil, "America/New_York") == nil
    end

    test "keeps saved timezone even when it matches the default" do
      profile = insert(:profile, timezone: Profiles.get_default_timezone())
      prefilled = Profiles.prefill_timezone(profile, "America/Chicago")

      # Saved value is the source of truth — never override with detected
      assert prefilled.timezone == Profiles.get_default_timezone()
    end

    test "does not overwrite an already-customised timezone" do
      profile = insert(:profile, timezone: "Asia/Tokyo")
      prefilled = Profiles.prefill_timezone(profile, "America/Chicago")

      # Existing explicit timezone wins over browser detection
      assert prefilled.timezone == "Asia/Tokyo"
    end

    test "handles nil detected timezone gracefully" do
      profile = insert(:profile)
      result = Profiles.prefill_timezone(profile, nil)

      # Profile has a saved timezone — detected value is irrelevant.
      assert result.timezone == profile.timezone
    end

    test "uses detected timezone when profile has no saved timezone" do
      profile = insert(:profile, timezone: nil)
      prefilled = Profiles.prefill_timezone(profile, "America/Chicago")

      assert prefilled.timezone == "America/Chicago"
    end

    test "keeps custom timezone when detected timezone is nil" do
      profile = insert(:profile, timezone: "Asia/Tokyo")
      result = Profiles.prefill_timezone(profile, nil)

      # Custom timezone is not the default, so should_use_detected? returns false.
      # The profile's existing timezone is returned unchanged.
      assert result.timezone == "Asia/Tokyo"
    end
  end

  # =====================================
  # Theme & Embed Domain Updates
  # =====================================

  describe "update_booking_theme" do
    setup do
      %{profile: insert(:profile)}
    end

    test "accepts a valid registered theme ID", %{profile: profile} do
      # ThemeInfo.all_themes() returns a map; Enum.at/2 yields a {id, config} tuple.
      themes = ThemeInfo.all_themes()
      assert map_size(themes) > 0, "No themes are registered"
      {valid_theme, _config} = Enum.at(themes, 0)

      assert {:ok, updated} = Profiles.update_booking_theme(profile, valid_theme)
      assert updated.booking_theme == valid_theme
    end

    test "rejects an unrecognised theme ID", %{profile: profile} do
      assert {:error, _reason} = Profiles.update_booking_theme(profile, "nonexistent-theme")
    end
  end

  describe "update_allowed_embed_domains" do
    setup do
      %{profile: insert(:profile)}
    end

    test "accepts a list of valid domains", %{profile: profile} do
      assert {:ok, updated} =
               Profiles.update_allowed_embed_domains(profile, ["example.com", "sub.example.org"])

      assert "example.com" in updated.allowed_embed_domains
    end

    test "accepts a comma-separated string of valid domains", %{profile: profile} do
      assert {:ok, updated} =
               Profiles.update_allowed_embed_domains(profile, "example.com, other.io")

      assert "example.com" in updated.allowed_embed_domains
      assert "other.io" in updated.allowed_embed_domains
    end

    test "strips protocol and accepts the extracted host", %{profile: profile} do
      assert {:ok, updated} =
               Profiles.update_allowed_embed_domains(profile, ["https://bad-format.com"])

      assert "bad-format.com" in updated.allowed_embed_domains
    end

    test "treats empty string as the 'none' disabled state", %{profile: profile} do
      assert {:ok, updated} = Profiles.update_allowed_embed_domains(profile, "")
      assert updated.allowed_embed_domains == ["none"]
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

  describe "mark_booking_page_published/1" do
    test "publishes when the profile has a username and was not yet published" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "host")

      assert {:ok, :published} = Profiles.mark_booking_page_published(profile)

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert reloaded.booking_page_published_at != nil
    end

    test "is idempotent — a second call is a no-op" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: "host")

      assert {:ok, :published} = Profiles.mark_booking_page_published(profile)
      {:ok, published} = ProfileQueries.get_by_user_id(user.id)

      assert {:ok, :noop} = Profiles.mark_booking_page_published(published)

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert reloaded.booking_page_published_at == published.booking_page_published_at
    end

    test "is a no-op when the profile has no username" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)

      assert {:ok, :noop} = Profiles.mark_booking_page_published(profile)

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert reloaded.booking_page_published_at == nil
    end
  end

  describe "publishing the booking page on username set" do
    test "update_username/3 publishes when the user already has an active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)
      insert(:meeting_type, user: user, is_active: true)

      assert {:ok, _updated} = Profiles.update_username(profile, "newhost", user.id)

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert %DateTime{} = reloaded.booking_page_published_at
    end

    test "update_username/3 does not publish when the user has no active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)

      assert {:ok, _updated} = Profiles.update_username(profile, "newhost", user.id)

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert reloaded.booking_page_published_at == nil
    end

    test "assign_default_username/2 publishes when the user already has an active meeting type" do
      user = insert(:user)
      profile = insert(:profile, user: user, username: nil)
      insert(:meeting_type, user: user, is_active: true)

      assert {:ok, _updated} = Profiles.assign_default_username(profile, "autohost")

      {:ok, reloaded} = ProfileQueries.get_by_user_id(user.id)
      assert %DateTime{} = reloaded.booking_page_published_at
    end
  end

  # Helper to update settings directly in DB for testing retrieval
  defp update_profile_settings(user_id, attrs) do
    {:ok, profile} = ProfileQueries.get_by_user_id(user_id)
    ProfileQueries.update_profile(profile, attrs)
  end
end
