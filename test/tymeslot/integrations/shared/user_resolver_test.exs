defmodule Tymeslot.Integrations.Common.UserResolverTest do
  @moduletag :integrations
  use Tymeslot.DataCase, async: true

  alias Tymeslot.Integrations.Common.UserResolver

  describe "resolve_user_integrations/2" do
  @moduletag :integrations
    test "returns integrations for a user" do
      user = insert(:user)
      _calendar_integration = insert(:calendar_integration, user: user)
      _video_integration = insert(:video_integration, user: user)

      assert [_integration] = UserResolver.resolve_user_integrations(user.id, :calendar)
      assert [_integration] = UserResolver.resolve_user_integrations(user.id, :video)
    end

    test "legacy support for user_id nil" do
      # Assuming user ID 1 exists or factory handles it
      # In this case we just check it doesn't crash
      assert [] = UserResolver.resolve_user_integrations(nil, :calendar)
    end
  end

  describe "validate_integration_attrs/2" do
    test "validates required fields for calendar" do
      valid_attrs = %{
        user_id: 1,
        name: "Cal",
        provider: "caldav",
        is_active: true,
        base_url: "http://test"
      }

      assert :ok = UserResolver.validate_integration_attrs(valid_attrs, :calendar)

      invalid_attrs = %{user_id: 1}
      assert {:error, message} = UserResolver.validate_integration_attrs(invalid_attrs, :calendar)
      assert message =~ "Missing required fields"
    end

    test "calendar-specific validation" do
      # Google requires access_token
      attrs = %{user_id: 1, name: "G", provider: "google", is_active: true}

      assert {:error, "OAuth providers require access_token"} =
               UserResolver.validate_integration_attrs(attrs, :calendar)

      # CalDAV requires base_url
      attrs = %{user_id: 1, name: "C", provider: "caldav", is_active: true}

      assert {:error, "CalDAV providers require base_url"} =
               UserResolver.validate_integration_attrs(attrs, :calendar)
    end
  end

  describe "create_or_update_integration/4" do
    test "creates new calendar integration" do
      user = insert(:user)

      attrs = %{
        user_id: user.id,
        name: "My Google",
        provider: "google",
        is_active: true,
        access_token: "token",
        base_url: "https://google.com"
      }

      assert {:ok, integration} =
               UserResolver.create_or_update_integration(user.id, :calendar, "google", attrs)

      assert integration.name == "My Google"
    end

    test "updates existing calendar integration" do
      user = insert(:user)

      existing =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          name: "Old Name",
          base_url: "https://google.com"
        )

      attrs = %{name: "New Name"}

      assert {:ok, updated} =
               UserResolver.create_or_update_integration(user.id, :calendar, "google", attrs)

      assert updated.id == existing.id
      assert updated.name == "New Name"
    end
  end

  describe "default_integration_attrs/2" do
    test "generates defaults" do
      attrs = UserResolver.default_integration_attrs(:calendar, "google")
      assert attrs.provider == "google"
      assert attrs.name == "Google Calendar"
      assert attrs.is_active == true
    end
  end
end
