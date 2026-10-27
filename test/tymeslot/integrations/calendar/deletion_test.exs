defmodule Tymeslot.Integrations.Calendar.DeletionTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Primary
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Security.Encryption

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

  defp insert_exchange(user, name, attrs \\ []) do
    insert(
      :calendar_integration,
      [
        user: user,
        provider: "exchange",
        name: name,
        base_url: "https://exchange.example.com/EWS/Exchange.asmx"
      ] ++ attrs
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
      Primary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete second integration (not primary)
      assert {:ok, :deleted} = Deletion.delete_with_primary_reassignment(user.id, integration2.id)

      # Verify deletion
      assert {:error, :not_found} =
               Management.get_calendar_integration(integration2.id, user.id)

      # Primary should still be the first integration
      assert {:ok, primary} = Primary.get_primary_calendar_integration(user.id)
      assert primary.id == integration1.id
    end

    test "deletes primary integration and promotes next one", %{user: user} do
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set first as primary
      Primary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete primary integration — the remaining one is promoted in its place
      assert {:ok, {:deleted_promoted, integration2.id}} ==
               Deletion.delete_with_primary_reassignment(user.id, integration1.id)

      assert {:error, :not_found} =
               Management.get_calendar_integration(integration1.id, user.id)

      assert {:ok, primary} = Primary.get_primary_calendar_integration(user.id)
      assert primary.id == integration2.id
    end

    test "deletes last integration and clears primary", %{user: user} do
      integration = insert(:calendar_integration, user: user)

      # Set as primary
      Primary.set_primary_calendar_integration(user.id, integration.id)

      # Delete last integration — nothing left to promote, so primary is cleared
      assert Deletion.delete_with_primary_reassignment(user.id, integration.id) ==
               {:ok, {:deleted_cleared_primary}}

      assert {:error, :not_found} =
               Management.get_calendar_integration(integration.id, user.id)

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
               Management.get_calendar_integration(integration.id, other_user.id)
    end

    test "handles deletion of multiple integrations sequentially", %{user: user} do
      # Insertion times are explicit because promotion takes the newest.
      integration1 =
        insert(:calendar_integration, user: user, inserted_at: ~N[2024-01-01 10:00:00])

      integration2 =
        insert(:calendar_integration, user: user, inserted_at: ~N[2024-01-02 10:00:00])

      integration3 =
        insert(:calendar_integration, user: user, inserted_at: ~N[2024-01-03 10:00:00])

      # Set first as primary
      Primary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete first (primary) - should promote the newest, the third
      assert {:ok, {:deleted_promoted, integration3.id}} ==
               Deletion.delete_with_primary_reassignment(user.id, integration1.id)

      # Delete second (non-primary)
      assert {:ok, :deleted} = Deletion.delete_with_primary_reassignment(user.id, integration2.id)

      # Delete third (now primary and last) - should clear
      assert Deletion.delete_with_primary_reassignment(user.id, integration3.id) ==
               {:ok, {:deleted_cleared_primary}}

      # All integrations should be deleted
      assert Management.list_calendar_integrations(user.id) == []
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
               Management.get_calendar_integration(integration.id, user.id)
    end

    test "promotes the newest remaining integration when deleting primary", %{user: user} do
      # One rule for every path that hands the primary on (delete, toggle,
      # pause): the newest eligible integration. Name does not decide: the
      # newest is deliberately the one sorting last by name.
      current_primary =
        insert(:calendar_integration,
          user: user,
          name: "A primary",
          inserted_at: ~N[2024-01-01 10:00:00]
        )

      _first_by_name =
        insert(:calendar_integration,
          user: user,
          name: "B candidate",
          inserted_at: ~N[2024-01-02 10:00:00]
        )

      newest =
        insert(:calendar_integration,
          user: user,
          name: "C candidate",
          inserted_at: ~N[2024-01-03 10:00:00]
        )

      Primary.set_primary_calendar_integration(user.id, current_primary.id)

      assert {:ok, {:deleted_promoted, newest.id}} ==
               Deletion.delete_with_primary_reassignment(user.id, current_primary.id)

      # The promoted integration is the one now recorded as primary
      assert {:ok, primary} = Primary.get_primary_calendar_integration(user.id)
      assert primary.id == newest.id
    end

    # A paused calendar would take no bookings, so it is never promoted, even
    # when it is the only other writable one.
    test "deleting the primary never promotes a paused integration", %{user: user} do
      primary = insert(:calendar_integration, user: user, inserted_at: ~N[2024-01-01 10:00:00])

      _paused =
        insert(:calendar_integration,
          user: user,
          is_active: false,
          inserted_at: ~N[2024-01-02 10:00:00]
        )

      Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, {:deleted_cleared_primary}} =
               Deletion.delete_with_primary_reassignment(user.id, primary.id)

      assert {:ok, %{primary_calendar_integration_id: nil}} =
               ProfileQueries.get_by_user_id(user.id)
    end

    test "deleting the primary with a subscription and a writable integration promotes the writable one",
         %{user: user} do
      primary = insert(:calendar_integration, user: user)
      writable = insert(:calendar_integration, user: user)
      _subscription = insert_subscription(user)

      Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, {:deleted_promoted, promoted_id}} =
               Deletion.delete_with_primary_reassignment(user.id, primary.id)

      assert promoted_id == writable.id

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == writable.id
    end

    test "deleting the primary can promote an Exchange mailbox, which now takes bookings", %{
      user: user
    } do
      # The journey: Google is primary, a CalDAV account and an Exchange
      # mailbox sit beside it, and the user removes Google. Promotion takes the
      # newest, so the Exchange mailbox is connected last. It was skipped here
      # while the EWS provider refused every write; now it wins like any other
      # writable integration.
      primary = insert(:calendar_integration, user: user, provider: "google", name: "A Google")

      _caldav =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          name: "C CalDAV",
          inserted_at: ~N[2024-01-02 10:00:00]
        )

      exchange = insert_exchange(user, "B Exchange", inserted_at: ~N[2024-01-03 10:00:00])

      Primary.set_primary_calendar_integration(user.id, primary.id)

      assert {:ok, {:deleted_promoted, promoted_id}} =
               Deletion.delete_with_primary_reassignment(user.id, primary.id)

      assert promoted_id == exchange.id

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == exchange.id
    end

    test "deleting the primary with only an Exchange mailbox remaining promotes it", %{
      user: user
    } do
      primary = insert(:calendar_integration, user: user)
      exchange = insert_exchange(user, "Exchange")

      Primary.set_primary_calendar_integration(user.id, primary.id)

      # Previously `{:deleted_cleared_primary}`: the user was left with no
      # primary at all. A mailbox that accepts a booking is a better answer.
      assert {:ok, {:deleted_promoted, promoted_id}} =
               Deletion.delete_with_primary_reassignment(user.id, primary.id)

      assert promoted_id == exchange.id

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == exchange.id
    end

    test "deleting the primary with only a subscription remaining clears the primary", %{
      user: user
    } do
      primary = insert(:calendar_integration, user: user)
      _subscription = insert_subscription(user)

      Primary.set_primary_calendar_integration(user.id, primary.id)

      assert Deletion.delete_with_primary_reassignment(user.id, primary.id) ==
               {:ok, {:deleted_cleared_primary}}

      assert {:ok, profile} = ProfileQueries.get_by_user_id(user.id)
      assert profile.primary_calendar_integration_id == nil
    end

    test "handles concurrent deletions gracefully", %{user: user} do
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set first as primary
      Primary.set_primary_calendar_integration(user.id, integration1.id)

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
      assert Management.list_calendar_integrations(user.id) == []

      assert {:error, :not_found} =
               Management.get_calendar_integration(integration1.id, user.id)

      assert {:error, :not_found} =
               Management.get_calendar_integration(integration2.id, user.id)
    end
  end
end
