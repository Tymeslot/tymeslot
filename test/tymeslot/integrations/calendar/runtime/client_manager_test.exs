defmodule Tymeslot.Integrations.Calendar.Runtime.ClientManagerTest do
  @moduledoc """
  Composition tests for `Tymeslot.Integrations.Calendar.Runtime.ClientManager`.

  ClientManager decides which calendar integration a booking writes to.
  The resolution order is: explicit Meeting integration → MeetingType
  integration → user's primary → first active integration. Previously
  untested, so these tests lock in the contract that wrappers further
  up the stack rely on.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.Runtime.ClientManager
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  setup do
    user = insert(:user)
    %{user: user}
  end

  describe "booking_client/1" do
    test "returns nil when the user has no calendar integration", %{user: user} do
      insert(:profile, user: user)

      assert ClientManager.booking_client(user.id) == nil
    end

    test "returns nil when no context is given", _ctx do
      assert ClientManager.booking_client(nil) == nil
      assert ClientManager.booking_client() == nil
    end

    test "returns a client map for a user with an active CalDAV integration", %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/default/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: integration.id)

      assert %{provider_type: :caldav, client: _c, provider_module: _m} =
               ClientManager.booking_client(user.id)
    end

    test "returns a client using the Meeting's explicit integration when active", %{user: user} do
      explicit =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/explicit/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: explicit.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: explicit.id,
        calendar_path: "/calendars/explicit/"
      }

      assert %{provider_type: :caldav} = ClientManager.booking_client(meeting)
    end

    test "falls back to the user's primary when the Meeting's integration is inactive", %{
      user: user
    } do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"]
        )

      inactive =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          calendar_paths: ["/calendars/inactive/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: inactive.id,
        calendar_path: "/calendars/inactive/event.ics"
      }

      assert %{provider_type: :caldav} = ClientManager.booking_client(meeting)
    end

    test "returns a client using the MeetingType's explicit integration when active", %{
      user: user
    } do
      explicit =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/mt-explicit/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: explicit.id)

      meeting_type = %MeetingTypeSchema{
        user_id: user.id,
        calendar_integration_id: explicit.id,
        target_calendar_id: "/calendars/mt-explicit/"
      }

      assert %{provider_type: :caldav} = ClientManager.booking_client(meeting_type)
    end

    test "falls back to the user's primary when the MeetingType's integration is inactive", %{
      user: user
    } do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"]
        )

      inactive =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          calendar_paths: ["/calendars/mt-inactive/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting_type = %MeetingTypeSchema{
        user_id: user.id,
        calendar_integration_id: inactive.id,
        target_calendar_id: "/calendars/mt-inactive/target/"
      }

      assert %{provider_type: :caldav} = ClientManager.booking_client(meeting_type)
    end
  end

  describe "get_booking_integration_info/1 — with a user id" do
    test "returns the primary integration's id and its first calendar path", %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: integration.id)

      assert {:ok, %{integration_id: id, calendar_path: path}} =
               ClientManager.get_booking_integration_info(user.id)

      assert id == integration.id
      assert path == "/calendars/primary/"
    end

    test "returns :no_integration when the user has no integrations", %{user: user} do
      insert(:profile, user: user)

      assert {:error, :no_integration} = ClientManager.get_booking_integration_info(user.id)
    end

    test "falls back to the first active integration when no primary is set", %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          name: "A",
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/only/"]
        )

      insert(:profile, user: user)

      assert {:ok, %{integration_id: id}} = ClientManager.get_booking_integration_info(user.id)
      assert id == integration.id
    end
  end

  describe "get_booking_integration_info/1 — with a Meeting" do
    test "uses the meeting's explicit integration when it is active", %{user: user} do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"]
        )

      explicit =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/explicit/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: explicit.id,
        calendar_path: "/calendars/explicit/event.ics"
      }

      assert {:ok, %{integration_id: id, calendar_path: path}} =
               ClientManager.get_booking_integration_info(meeting)

      assert id == explicit.id
      assert path == "/calendars/explicit/event.ics"
    end

    test "falls back to the organiser's primary when the meeting's integration is inactive", %{
      user: user
    } do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"]
        )

      inactive =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          calendar_paths: ["/calendars/inactive/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: inactive.id,
        calendar_path: "/calendars/inactive/event.ics"
      }

      assert {:ok, %{integration_id: id}} =
               ClientManager.get_booking_integration_info(meeting)

      assert id == primary.id
    end

    test "falls back to the organiser's primary when the meeting has no stored integration", %{
      user: user
    } do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: nil,
        calendar_path: nil
      }

      assert {:ok, %{integration_id: id}} =
               ClientManager.get_booking_integration_info(meeting)

      assert id == primary.id
    end
  end

  describe "get_booking_integration_info/1 — with a MeetingType" do
    test "uses the meeting type's explicit integration when it is active", %{user: user} do
      explicit =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/explicit/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: explicit.id)

      meeting_type = %MeetingTypeSchema{
        user_id: user.id,
        calendar_integration_id: explicit.id,
        target_calendar_id: "/calendars/explicit/target/"
      }

      assert {:ok, %{integration_id: id, calendar_path: path}} =
               ClientManager.get_booking_integration_info(meeting_type)

      assert id == explicit.id
      assert path == "/calendars/explicit/target/"
    end

    test "falls back to the user's primary when the meeting type's integration is inactive", %{
      user: user
    } do
      primary =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/primary/"]
        )

      inactive =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: false,
          calendar_paths: ["/calendars/mt-inactive/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: primary.id)

      meeting_type = %MeetingTypeSchema{
        user_id: user.id,
        calendar_integration_id: inactive.id,
        target_calendar_id: "/calendars/mt-inactive/target/"
      }

      assert {:ok, %{integration_id: id}} =
               ClientManager.get_booking_integration_info(meeting_type)

      assert id == primary.id
    end
  end

  describe "resolve_client/1" do
    test "resolves a Meeting's integration directly when stored", %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/meeting/"]
        )

      insert(:profile, user: user)

      meeting = %MeetingSchema{
        organizer_user_id: user.id,
        calendar_integration_id: integration.id,
        calendar_path: "/calendars/meeting/"
      }

      assert %{provider_type: :caldav} = ClientManager.resolve_client(meeting)
    end

    test "resolves the user's primary client when given a user id", %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/only/"]
        )

      insert(:profile, user: user, primary_calendar_integration_id: integration.id)

      assert %{provider_type: :caldav} = ClientManager.resolve_client(user.id)
    end

    test "returns nil when given nil", _ctx do
      assert ClientManager.resolve_client(nil) == nil
    end

    test "resolves via {integration_id, user_id} tuple", %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/tuple/"]
        )

      insert(:profile, user: user)

      assert %{provider_type: :caldav} = ClientManager.resolve_client({integration.id, user.id})
    end

    test "returns nil for an unrelated user that has no integrations", _ctx do
      stranger = insert(:user)
      insert(:profile, user: stranger)

      assert ClientManager.resolve_client(stranger.id) == nil
    end
  end

  describe "get_client_by_integration_id/2" do
    test "returns a client whose provider_type matches the integration's provider", %{user: user} do
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/byid/"]
        )

      insert(:profile, user: user)

      assert %{provider_type: :caldav} =
               ClientManager.get_client_by_integration_id(integration.id, user.id)
    end

    test "returns nil when the integration does not belong to the user", %{user: user} do
      other_user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: other_user,
          provider: "caldav",
          is_active: true,
          calendar_paths: ["/calendars/other/"]
        )

      insert(:profile, user: user)

      assert ClientManager.get_client_by_integration_id(integration.id, user.id) == nil
    end
  end
end
