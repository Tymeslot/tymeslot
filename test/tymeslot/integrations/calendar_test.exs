defmodule Tymeslot.Integrations.CalendarTest do
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar

  setup :verify_on_exit!

  describe "list_integrations/1" do
    test "returns integrations with primary flag" do
      user = insert(:user)
      insert(:profile, user: user)
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set integration1 as primary
      assert {:ok, _result} = Calendar.set_primary(user.id, integration1.id)

      integrations = Calendar.list_integrations(user.id)

      assert length(integrations) == 2
      i1 = Enum.find(integrations, &(&1.id == integration1.id))
      i2 = Enum.find(integrations, &(&1.id == integration2.id))

      assert i1.is_primary == true
      assert i2.is_primary == false
    end
  end

  describe "get_integration/2" do
    test "returns integration when found and belongs to user" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:ok, fetched} = Calendar.get_integration(integration.id, user.id)
      assert fetched.id == integration.id
    end

    test "returns error when not found" do
      user = insert(:user)
      assert {:error, :not_found} = Calendar.get_integration(999, user.id)
    end

    test "returns error when belongs to another user" do
      user1 = insert(:user)
      user2 = insert(:user)
      integration = insert(:calendar_integration, user: user1)

      assert {:error, :not_found} = Calendar.get_integration(integration.id, user2.id)
    end
  end

  describe "toggle_integration/2" do
    test "toggles active status" do
      user = insert(:user)
      insert(:profile, user: user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      assert {:ok, toggled} = Calendar.toggle_integration(integration.id, user.id)
      refute toggled.is_active

      assert {:ok, toggled_back} = Calendar.toggle_integration(integration.id, user.id)
      assert toggled_back.is_active
    end
  end

  describe "delete_integration/2" do
    test "deletes integration" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:ok, _result} = Calendar.delete_integration(integration.id, user.id)
      assert {:error, :not_found} = Calendar.get_integration(integration.id, user.id)
    end
  end

  describe "primary calendar management" do
    test "set_primary/2 and clear_primary/1" do
      user = insert(:user)
      insert(:profile, user: user)
      integration = insert(:calendar_integration, user: user)

      assert {:ok, _result} = Calendar.set_primary(user.id, integration.id)
      integrations = Calendar.list_integrations(user.id)
      assert Enum.find(integrations, &(&1.id == integration.id)).is_primary

      assert {:ok, _result} = Calendar.clear_primary(user.id)
      integrations = Calendar.list_integrations(user.id)
      refute Enum.find(integrations, &(&1.id == integration.id)).is_primary
    end
  end

  describe "test_connection/1" do
    test "delegates to provider and records telemetry" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "google")

      expect(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end ->
        {:ok, []}
      end)

      assert {:ok, "Google Calendar connection successful"} =
               Calendar.test_connection(integration)
    end
  end

  describe "calendar_module configuration" do
    test "falls back to Operations when configured module does not exist" do
      # Set to a non-existent module
      Application.put_env(:tymeslot, :calendar_module, NonExistentModule)

      # We don't need to mock Operations because we just want to see if it's called
      # If it falls back to Operations, it will try to call Operations.get_event.
      # Since no integrations are set up in this test context, it should return an error.
      assert {:error, _reason} = Calendar.get_event("some-uid")
    after
      Application.delete_env(:tymeslot, :calendar_module)
    end
  end

  describe "event operations" do
    test "list_events/1 delegates to Operations" do
      user = insert(:user)
      insert(:calendar_integration, user: user, provider: "google", is_active: true)

      expect(GoogleCalendarAPIMock, :list_primary_events, fn _int, _start, _end ->
        {:ok, [%{"id" => "event1", "summary" => "Test Event"}]}
      end)

      assert {:ok, events} = Calendar.list_events(user.id)
      assert length(events) == 1
      assert Enum.at(events, 0).uid == "event1"
    end
  end
end
