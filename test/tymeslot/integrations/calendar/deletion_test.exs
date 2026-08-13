defmodule Tymeslot.Integrations.Calendar.DeletionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Mox
  import Tymeslot.Factory
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  defp insert_subscription(user) do
    insert(:calendar_integration,
      user: user,
      provider: "ics_url",
      base_url: "https://feeds.example.com",
      username_encrypted: nil,
      password_encrypted: nil,
      subscription_url_encrypted: Encryption.encrypt("https://feeds.example.com/feed.ics")
    )
  end

  describe "delete_with_primary_reassignment/2" do
    setup do
      user = insert(:user)
      # The primary calendar is recorded on the profile, so without one
      # set_primary_calendar_integration/2 is a no-op and the promotion and
      # clear-primary branches below would never be reached.
      insert(:profile, user: user)

      %{user: user}
    end

    test "deletes non-primary integration without reassignment", %{user: user} do
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set first as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete second integration (not primary)
      assert {:ok, :deleted} = Deletion.delete_with_primary_reassignment(user.id, integration2.id)

      # Verify deletion
      assert {:error, :not_found} =
               CalendarManagement.get_calendar_integration(integration2.id, user.id)

      # Primary should still be the first integration
      assert {:ok, primary} = CalendarPrimary.get_primary_calendar_integration(user.id)
      assert primary.id == integration1.id
    end

    test "deletes primary integration and promotes next one", %{user: user} do
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set first as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete primary integration — the remaining one is promoted in its place
      assert {:ok, {:deleted_promoted, integration2.id}} ==
               Deletion.delete_with_primary_reassignment(user.id, integration1.id)

      assert {:error, :not_found} =
               CalendarManagement.get_calendar_integration(integration1.id, user.id)

      assert {:ok, primary} = CalendarPrimary.get_primary_calendar_integration(user.id)
      assert primary.id == integration2.id
    end

    test "deletes last integration and clears primary", %{user: user} do
      integration = insert(:calendar_integration, user: user)

      # Set as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration.id)

      # Delete last integration — nothing left to promote, so primary is cleared
      assert Deletion.delete_with_primary_reassignment(user.id, integration.id) ==
               {:ok, {:deleted_cleared_primary}}

      assert {:error, :not_found} =
               CalendarManagement.get_calendar_integration(integration.id, user.id)

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil
    end

    test "returns error when integration not found", %{user: user} do
      result = Deletion.delete_with_primary_reassignment(user.id, 99_999)

      assert {:error, :not_found} = result
    end

    test "prevents deletion of integration belonging to different user", %{user: user} do
      other_user = insert(:user)
      integration = insert(:calendar_integration, user: other_user)

      result = Deletion.delete_with_primary_reassignment(user.id, integration.id)

      assert {:error, :not_found} = result

      # Integration should still exist
      assert {:ok, _updated_integration} =
               CalendarManagement.get_calendar_integration(integration.id, other_user.id)
    end

    test "handles deletion of multiple integrations sequentially", %{user: user} do
      # Names are explicit because promotion orders by name; the factory's
      # generated names sort unstably once its counter crosses a digit boundary.
      integration1 = insert(:calendar_integration, user: user, name: "A")
      integration2 = insert(:calendar_integration, user: user, name: "B")
      integration3 = insert(:calendar_integration, user: user, name: "C")

      # Set first as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete first (primary) - should promote second
      assert {:ok, {:deleted_promoted, integration2.id}} ==
               Deletion.delete_with_primary_reassignment(user.id, integration1.id)

      # Delete third (non-primary)
      assert {:ok, :deleted} = Deletion.delete_with_primary_reassignment(user.id, integration3.id)

      # Delete second (now primary and last) - should clear
      assert Deletion.delete_with_primary_reassignment(user.id, integration2.id) ==
               {:ok, {:deleted_cleared_primary}}

      # All integrations should be deleted
      assert CalendarManagement.list_calendar_integrations(user.id) == []
    end

    test "clears target_calendar_id on meeting types when integration is deleted", %{user: user} do
      integration = insert(:calendar_integration, user: user)

      meeting_type =
        insert(:meeting_type,
          user: user,
          calendar_integration: integration,
          target_calendar_id: "calendar-123"
        )

      assert {:ok, _result} = Deletion.delete_with_primary_reassignment(user.id, integration.id)

      reloaded = MeetingTypeQueries.get_meeting_type!(meeting_type.id)
      assert reloaded.calendar_integration_id == nil
      assert reloaded.target_calendar_id == nil
    end

    test "handles deletion when no primary is set", %{user: user} do
      integration = insert(:calendar_integration, user: user)

      # Don't set as primary

      result = Deletion.delete_with_primary_reassignment(user.id, integration.id)

      # Should delete without promotion
      assert {:ok, :deleted} = result

      # Verify deletion
      assert {:error, :not_found} =
               CalendarManagement.get_calendar_integration(integration.id, user.id)
    end

    test "promotes the first remaining integration by name when deleting primary", %{user: user} do
      # Promotion takes the head of `list_all_for_user/1`, ordered
      # `desc: is_active, asc: name`. Name decides, not recency: the candidate
      # created last is deliberately the one sorting last by name.
      current_primary =
        insert(:calendar_integration,
          user: user,
          name: "A primary",
          inserted_at: ~N[2024-01-01 10:00:00]
        )

      first_by_name =
        insert(:calendar_integration,
          user: user,
          name: "B candidate",
          inserted_at: ~N[2024-01-02 10:00:00]
        )

      _newest =
        insert(:calendar_integration,
          user: user,
          name: "C candidate",
          inserted_at: ~N[2024-01-03 10:00:00]
        )

      CalendarPrimary.set_primary_calendar_integration(user.id, current_primary.id)

      assert {:ok, {:deleted_promoted, first_by_name.id}} ==
               Deletion.delete_with_primary_reassignment(user.id, current_primary.id)

      # The promoted integration is the one now recorded as primary
      assert {:ok, primary} = CalendarPrimary.get_primary_calendar_integration(user.id)
      assert primary.id == first_by_name.id
    end

    test "deleting the primary with a subscription and a writable integration promotes the writable one",
         %{user: user} do
      primary = insert(:calendar_integration, user: user)
      writable = insert(:calendar_integration, user: user)
      _subscription = insert_subscription(user)

      CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, {:deleted_promoted, promoted_id}} =
               Deletion.delete_with_primary_reassignment(user.id, primary.id)

      assert promoted_id == writable.id

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == writable.id
    end

    test "deleting the primary with only a subscription remaining clears the primary", %{
      user: user
    } do
      primary = insert(:calendar_integration, user: user)
      _subscription = insert_subscription(user)

      CalendarPrimary.set_primary_calendar_integration(user.id, primary.id)

      assert Deletion.delete_with_primary_reassignment(user.id, primary.id) ==
               {:ok, {:deleted_cleared_primary}}

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil
    end

    test "handles concurrent deletions gracefully", %{user: user} do
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set first as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration1.id)

      # Attempt concurrent deletions
      task1 =
        Task.async(fn -> Deletion.delete_with_primary_reassignment(user.id, integration1.id) end)

      task2 =
        Task.async(fn -> Deletion.delete_with_primary_reassignment(user.id, integration2.id) end)

      results = Task.await_many([task1, task2], 5000)

      # Each task owns a distinct integration, so both deletions must succeed
      # whatever order they interleave in.
      assert [{:ok, _first}, {:ok, _second}] = results

      # And both rows really are gone — the point of the exercise.
      assert CalendarManagement.list_calendar_integrations(user.id) == []

      assert {:error, :not_found} =
               CalendarManagement.get_calendar_integration(integration1.id, user.id)

      assert {:error, :not_found} =
               CalendarManagement.get_calendar_integration(integration2.id, user.id)
    end
  end

  describe "delete_with_primary_reassignment/2 — mirror teardown" do
    setup do
      user = insert(:user)
      insert(:profile, user: user)
      source = insert(:calendar_integration, user: user, provider: "google")
      target = insert(:calendar_integration, user: user, provider: "google")

      link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: target.id
        )

      %{user: user, source: source, target: target, link: link}
    end

    test "withdraws the placeholders living on the integration being disconnected", %{
      user: user,
      target: target,
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")
      test_pid = self()

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, {integration_id, _user_id} ->
        # Before the delete transaction opens: the integration must still be
        # there, since the provider call is made in its name.
        assert Repo.get(CalendarIntegrationSchema, target.id)
        send(test_pid, {:withdrawn, uid, integration_id})
        :ok
      end)

      assert {:ok, _outcome} = Deletion.delete_with_primary_reassignment(user.id, target.id)

      assert_received {:withdrawn, "mirror-uid-1", integration_id}
      assert integration_id == target.id
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
      refute Repo.get(CalendarIntegrationSchema, target.id)
    end

    test "withdraws the placeholders the disconnected integration caused elsewhere", %{
      user: user,
      source: source,
      target: target,
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")
      test_pid = self()

      # The SOURCE is going. Its placeholders sit on the target, which is
      # staying connected — nothing else would ever remove them.
      expect(Tymeslot.CalendarMock, :delete_event, fn uid, {integration_id, _user_id} ->
        send(test_pid, {:withdrawn, uid, integration_id})
        :ok
      end)

      assert {:ok, _outcome} = Deletion.delete_with_primary_reassignment(user.id, source.id)

      assert_received {:withdrawn, "mirror-uid-1", integration_id}
      assert integration_id == target.id
      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "aborts the disconnect when a placeholder cannot be withdrawn", %{
      user: user,
      target: target,
      link: link
    } do
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context ->
        {:error, :service_unavailable}
      end)

      assert {:error, :service_unavailable} =
               Deletion.delete_with_primary_reassignment(user.id, target.id)

      # Deleting the integration would cascade the link and its mapping away,
      # stranding the busy block with nothing naming it.
      assert Repo.get(CalendarIntegrationSchema, target.id)
      assert %{state: "pending_delete"} = Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "an integration with no links is disconnected without a provider call", %{user: user} do
      lone = insert(:calendar_integration, user: user, provider: "google")

      assert {:ok, _outcome} = Deletion.delete_with_primary_reassignment(user.id, lone.id)
      refute Repo.get(CalendarIntegrationSchema, lone.id)
    end

    test "refuses a stranger's integration before touching any placeholder", %{link: link} do
      stranger = insert(:user)
      mirror = mirror_for_link(link, source_uid: "src-1", target_uid: "mirror-uid-1")

      assert {:error, :not_found} =
               Deletion.delete_with_primary_reassignment(
                 stranger.id,
                 link.target_integration_id
               )

      assert Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end
  end
end
