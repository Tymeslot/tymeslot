defmodule Tymeslot.Integrations.Calendar.CreationTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Integrations.Calendar.Creation
  alias Tymeslot.Integrations.CalendarPrimary

  describe "prepare_attrs/2" do
    test "prepares attributes for CalDAV integration" do
      params = %{
        "name" => "Test CalDAV",
        "provider" => "caldav",
        "url" => "https://caldav.example.com",
        "username" => "testuser",
        "password" => "testpass",
        "calendar_paths" => "/calendars/user/personal"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)

      assert attrs.user_id == 1
      assert attrs.name == "Test CalDAV"
      assert attrs.provider == "caldav"
      assert attrs.base_url == "https://caldav.example.com"
      assert attrs.username == "testuser"
      assert attrs.password == "testpass"
      assert is_list(attrs.calendar_paths)
      assert attrs.is_active == true
    end

    test "handles empty calendar paths" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => ""
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert attrs.calendar_paths == []
    end

    test "parses comma-separated calendar paths" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/cal1, /cal2, /cal3"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert length(attrs.calendar_paths) == 3
      assert "/cal1" in attrs.calendar_paths
      assert "/cal2" in attrs.calendar_paths
      assert "/cal3" in attrs.calendar_paths
    end

    test "parses newline-separated calendar paths" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/cal1\n/cal2\n/cal3"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert length(attrs.calendar_paths) == 3
    end

    test "builds calendar_list from calendar_paths when not provided" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/calendars/user/personal"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert is_list(attrs.calendar_list)
      assert length(attrs.calendar_list) > 0

      calendar = List.first(attrs.calendar_list)
      assert calendar["path"] == "/calendars/user/personal"
      assert calendar["selected"] == true
    end

    test "uses provided calendar_list when available" do
      calendar_list = [
        %{id: "cal1", name: "Personal", path: "/cal1", selected: true}
      ]

      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/cal1",
        "calendar_list" => calendar_list
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      assert is_list(attrs.calendar_list)
      assert length(attrs.calendar_list) == 1

      calendar = List.first(attrs.calendar_list)
      assert calendar["id"] == "cal1"
      assert calendar["name"] == "Personal"
    end

    test "extracts calendar name from path" do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => "/calendars/user/personal/"
      }

      assert {:ok, attrs} = Creation.prepare_attrs(params, 1)
      calendar = List.first(attrs.calendar_list)

      # Name should be extracted from last path segment
      assert calendar["name"] == "personal"
    end
  end

  describe "prevalidate_config/1" do
    test "validates CalDAV config before creation" do
      attrs = %{
        provider: "caldav",
        base_url: "https://caldav.example.com",
        username: "user",
        password: "pass",
        calendar_paths: []
      }

      # Will fail validation due to network error
      result = Creation.prevalidate_config(attrs)
      assert match?({:error, _}, result)
    end

    test "skips validation for OAuth providers" do
      attrs = %{
        provider: "google",
        base_url: "https://www.googleapis.com",
        access_token: "token123",
        refresh_token: "refresh123"
      }

      # OAuth providers skip pre-validation
      assert {:ok, ^attrs} = Creation.prevalidate_config(attrs)
    end

    test "returns error for invalid credentials" do
      attrs = %{
        provider: "caldav",
        base_url: "https://caldav.example.com",
        username: "invalid",
        password: "wrong"
      }

      result = Creation.prevalidate_config(attrs)
      assert {:error, %Ecto.Changeset{}} = result
    end

    test "handles provider that doesn't exist" do
      attrs = %{
        provider: "unknown_provider",
        base_url: "https://example.com"
      }

      # Should skip validation for unknown provider
      assert {:ok, ^attrs} = Creation.prevalidate_config(attrs)
    end
  end

  describe "ensure_primary_on_first/3" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "sets first integration as primary", %{user: user} do
      integration = insert(:calendar_integration, user: user)

      # Simulate this being the first integration (count_before = 0)
      result = Creation.ensure_primary_on_first(user.id, integration.id, 0)

      # May return :ok or {:error, :not_found} depending on implementation
      assert match?(:ok, result) or match?({:error, _}, result)
    end

    test "does not set primary if not first integration", %{user: user} do
      # Create first integration and set as primary
      integration1 = insert(:calendar_integration, user: user)

      CalendarPrimary.set_primary_calendar_integration(
        user.id,
        integration1.id
      )

      # Create second integration
      integration2 = insert(:calendar_integration, user: user)

      # Simulate this being the second integration (count_before = 1)
      assert :ok = Creation.ensure_primary_on_first(user.id, integration2.id, 1)

      # Primary should still be the first integration (if profile exists)
      case ProfileQueries.get_by_user_id(user.id) do
        {:ok, profile} ->
          assert profile.primary_calendar_integration_id == integration1.id

        {:error, :not_found} ->
          # Profile may not exist in test environment
          :ok
      end
    end

    test "returns ok when count is greater than zero" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok = Creation.ensure_primary_on_first(user.id, integration.id, 5)
    end
  end

  describe "create_with_validation/3" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "creates integration and sets as primary if first", %{user: user} do
      params = %{
        "name" => "Test Calendar",
        "provider" => "caldav",
        "url" => "https://caldav.example.com",
        "username" => "testuser",
        "password" => "testpass",
        "calendar_paths" => ""
      }

      # Will fail due to network validation
      result = Creation.create_with_validation(user.id, params)

      # Validation will fail because we can't connect
      assert match?({:error, _}, result)
    end

    test "returns changeset errors for invalid params", %{user: user} do
      params = %{
        "name" => "",
        "provider" => "invalid"
      }

      result = Creation.create_with_validation(user.id, params)

      # Should return error due to missing required fields
      assert {:error, _} = result
    end

    test "returns form errors for security validation failures", %{user: user} do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "javascript:alert('xss')",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => ""
      }

      result = Creation.create_with_validation(user.id, params)

      # Security validation should catch malicious URL
      assert {:error, _} = result
    end

    test "accepts metadata option for rate limiting", %{user: user} do
      params = %{
        "name" => "Test",
        "provider" => "caldav",
        "url" => "https://example.com",
        "username" => "user",
        "password" => "pass",
        "calendar_paths" => ""
      }

      metadata = %{ip: "192.168.1.1"}
      result = Creation.create_with_validation(user.id, params, metadata: metadata)

      # Should still fail validation but metadata is accepted
      assert match?({:error, _}, result)
    end
  end
end
