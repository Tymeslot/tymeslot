defmodule Tymeslot.CalendarGrid.UndeliveredUpdatesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.UndeliveredUpdates

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user)
    %{user: user, integration: integration}
  end

  describe "note_delivery/4" do
    test "a failure records the guest and a later delivery clears them", %{
      user: user,
      integration: integration
    } do
      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-1", "a@example.com", {:error, :x})

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") == [
               "a@example.com"
             ]

      # A claim an earlier run already took reports a bare `:ok`.
      :ok = UndeliveredUpdates.note_delivery(integration.id, "evt-1", "a@example.com", :ok)
      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") == []
    end

    test "keeps each event's guests apart", %{user: user, integration: integration} do
      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-1", "a@example.com", {:error, :x})

      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-2", "b@example.com", {:error, :x})

      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-2", "a@example.com", {:ok, "sent"})

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") == [
               "a@example.com"
             ]

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-2") == [
               "b@example.com"
             ]
    end

    test "records nothing for an integration that is gone" do
      assert :ok = UndeliveredUpdates.note_delivery(-1, "evt-1", "a@example.com", {:error, :x})
    end
  end

  describe "list_for_event/3 and dismiss/3" do
    test "show and clear nothing on an integration the user does not own", %{
      user: user,
      integration: integration
    } do
      stranger = insert(:user)

      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-1", "a@example.com", {:error, :x})

      assert UndeliveredUpdates.list_for_event(stranger.id, integration.id, "evt-1") == []
      :ok = UndeliveredUpdates.dismiss(stranger.id, integration.id, "evt-1")

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") == [
               "a@example.com"
             ]
    end

    test "dismiss clears every guest of the event and only that event", %{
      user: user,
      integration: integration
    } do
      for email <- ["a@example.com", "b@example.com"] do
        :ok = UndeliveredUpdates.note_delivery(integration.id, "evt-1", email, {:error, :x})
      end

      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-2", "c@example.com", {:error, :x})

      :ok = UndeliveredUpdates.dismiss(user.id, integration.id, "evt-1")

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") == []

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-2") == [
               "c@example.com"
             ]
    end
  end

  describe "events_deleted/3" do
    test "forgets the notices of the events named, and only on the user's integration", %{
      user: user,
      integration: integration
    } do
      stranger = insert(:user)

      for uid <- ["evt-1", "evt-2", "evt-3"] do
        :ok = UndeliveredUpdates.note_delivery(integration.id, uid, "a@example.com", {:error, :x})
      end

      :ok = UndeliveredUpdates.events_deleted(stranger.id, integration.id, ["evt-1"])
      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") != []

      :ok = UndeliveredUpdates.events_deleted(user.id, integration.id, ["evt-1", "evt-2"])

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") == []
      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-2") == []

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-3") == [
               "a@example.com"
             ]
    end
  end

  describe "series_rewritten/2" do
    test "moves each event's notices to its successor and forgets one with none", %{
      user: user,
      integration: integration
    } do
      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-1", "a@example.com", {:error, :x})

      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-2", "b@example.com", {:error, :x})

      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-3", "c@example.com", {:error, :x})

      # The moves chain: evt-1 takes evt-2's uid while evt-2 moves on.
      :ok =
        UndeliveredUpdates.series_rewritten(user.id, [
          {{integration.id, "evt-1"}, {integration.id, "evt-2"}},
          {{integration.id, "evt-2"}, {integration.id, "evt-4"}},
          {{integration.id, "evt-3"}, nil}
        ])

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") == []

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-2") == [
               "a@example.com"
             ]

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-4") == [
               "b@example.com"
             ]

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-3") == []
    end

    test "moves nothing on an integration the user does not own", %{
      user: user,
      integration: integration
    } do
      stranger = insert(:user)

      :ok =
        UndeliveredUpdates.note_delivery(integration.id, "evt-1", "a@example.com", {:error, :x})

      :ok =
        UndeliveredUpdates.series_rewritten(stranger.id, [{{integration.id, "evt-1"}, nil}])

      assert UndeliveredUpdates.list_for_event(user.id, integration.id, "evt-1") == [
               "a@example.com"
             ]
    end
  end
end
