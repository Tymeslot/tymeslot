defmodule Tymeslot.Meetings.MeetingQueriesCalendarSyncTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries
  @moduletag :calendar

  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema

  defp create_meeting_with_calendar(overrides \\ %{}) do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user)

    meeting =
      insert(
        :meeting,
        Map.to_list(
          Map.merge(
            %{
              organizer_user: user,
              calendar_integration_id: integration.id,
              provider_event_id: "provider-event-#{System.unique_integer([:positive])}",
              uid: "meeting-uid-#{System.unique_integer([:positive])}"
            },
            overrides
          )
        )
      )

    {user, integration, meeting}
  end

  describe "get_by_provider_event_id/2" do
    test "returns meeting when found" do
      {_user, integration, meeting} = create_meeting_with_calendar()

      assert {:ok, found} =
               MeetingQueries.get_by_provider_event_id(
                 integration.id,
                 meeting.provider_event_id
               )

      assert found.id == meeting.id
    end

    test "returns :not_found when no match" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:error, :not_found} =
               MeetingQueries.get_by_provider_event_id(integration.id, "nonexistent")
    end

    test "scopes to integration" do
      {_user, _int1, meeting} = create_meeting_with_calendar()
      user2 = insert(:user)
      int2 = insert(:calendar_integration, user: user2)

      assert {:error, :not_found} =
               MeetingQueries.get_by_provider_event_id(
                 int2.id,
                 meeting.provider_event_id
               )
    end
  end

  describe "get_by_uid_and_integration/2" do
    test "returns meeting when found by uid" do
      {_user, integration, meeting} = create_meeting_with_calendar()

      assert {:ok, found} =
               MeetingQueries.get_by_uid_and_integration(integration.id, meeting.uid)

      assert found.id == meeting.id
    end

    test "returns :not_found when no match" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert {:error, :not_found} =
               MeetingQueries.get_by_uid_and_integration(integration.id, "nonexistent")
    end
  end

  describe "list_by_provider_event_ids/2" do
    test "returns a map from provider_event_id to meeting" do
      {_user, integration, meeting} = create_meeting_with_calendar()

      result =
        MeetingQueries.list_by_provider_event_ids(
          integration.id,
          [meeting.provider_event_id]
        )

      assert %{^result => _value} = %{result => :ok}
      assert Map.get(result, meeting.provider_event_id).id == meeting.id
    end

    test "returns empty map for empty list" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert %{} = MeetingQueries.list_by_provider_event_ids(integration.id, [])
    end

    test "returns empty map for list containing only nil values" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert %{} = MeetingQueries.list_by_provider_event_ids(integration.id, [nil, nil])
    end

    test "excludes nil values from lookup but returns matches for non-nil ids" do
      {_user, integration, meeting} = create_meeting_with_calendar()

      result =
        MeetingQueries.list_by_provider_event_ids(
          integration.id,
          [nil, meeting.provider_event_id, nil]
        )

      assert map_size(result) == 1
      assert Map.get(result, meeting.provider_event_id).id == meeting.id
    end

    test "does not return meetings from a different integration" do
      {_user, _int1, meeting} = create_meeting_with_calendar()
      user2 = insert(:user)
      int2 = insert(:calendar_integration, user: user2)

      result =
        MeetingQueries.list_by_provider_event_ids(int2.id, [meeting.provider_event_id])

      assert result == %{}
    end
  end

  describe "update_calendar_sync_status/2" do
    test "sets status to externally_deleted" do
      {_user, _integration, meeting} = create_meeting_with_calendar()

      assert {:ok, updated} =
               MeetingQueries.update_calendar_sync_status(meeting.id, "externally_deleted")

      assert updated.calendar_sync_status == "externally_deleted"
    end

    test "sets status to externally_modified" do
      {_user, _integration, meeting} = create_meeting_with_calendar()

      assert {:ok, updated} =
               MeetingQueries.update_calendar_sync_status(meeting.id, "externally_modified")

      assert updated.calendar_sync_status == "externally_modified"
    end

    test "clears dismissed_at on update" do
      {_user, _integration, meeting} = create_meeting_with_calendar()

      # Set dismissed_at first
      MeetingSchema
      |> where([m], m.id == ^meeting.id)
      |> Repo.update_all(
        set: [
          calendar_sync_status: "externally_modified",
          calendar_sync_status_dismissed_at: DateTime.utc_now(:second)
        ]
      )

      assert {:ok, updated} =
               MeetingQueries.update_calendar_sync_status(meeting.id, "externally_deleted")

      assert is_nil(updated.calendar_sync_status_dismissed_at)
    end

    test "returns :not_found for non-existent meeting" do
      assert {:error, :not_found} =
               MeetingQueries.update_calendar_sync_status(
                 UUID.generate(),
                 "externally_deleted"
               )
    end
  end

  describe "update_calendar_sync_status_if_changed/2" do
    test "updates status when different" do
      {_user, _integration, meeting} = create_meeting_with_calendar()

      assert {:ok, updated} =
               MeetingQueries.update_calendar_sync_status_if_changed(
                 meeting.id,
                 "externally_deleted"
               )

      assert updated.calendar_sync_status == "externally_deleted"
    end

    test "returns :already_set when status matches" do
      {_user, _integration, meeting} = create_meeting_with_calendar()

      # Set status first
      {:ok, _meeting} =
        MeetingQueries.update_calendar_sync_status(meeting.id, "externally_deleted")

      assert {:ok, :already_set} =
               MeetingQueries.update_calendar_sync_status_if_changed(
                 meeting.id,
                 "externally_deleted"
               )
    end

    test "returns :not_found for non-existent meeting" do
      assert {:error, :not_found} =
               MeetingQueries.update_calendar_sync_status_if_changed(
                 UUID.generate(),
                 "externally_deleted"
               )
    end
  end
end
