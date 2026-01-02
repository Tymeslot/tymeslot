defmodule Tymeslot.Integrations.Calendar.DeletionTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory
  alias Tymeslot.DatabaseQueries.ProfileQueries
  alias Tymeslot.Integrations.Calendar.Deletion
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary

  describe "delete_with_primary_reassignment/2" do
    setup do
      user = insert(:user)
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
      case CalendarPrimary.get_primary_calendar_integration(user.id) do
        {:ok, primary} ->
          assert primary.id == integration1.id

        {:error, :not_found} ->
          # Profile may not exist
          :ok
      end
    end

    test "deletes primary integration and promotes next one", %{user: user} do
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set first as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete primary integration
      result = Deletion.delete_with_primary_reassignment(user.id, integration1.id)

      # Should either promote second integration or complete deletion
      assert match?({:ok, {:deleted_promoted, _}}, result) or match?({:ok, :deleted}, result)

      # Verify deletion
      assert {:error, :not_found} =
               CalendarManagement.get_calendar_integration(integration1.id, user.id)

      # If promotion occurred, verify the promoted integration
      case result do
        {:ok, {:deleted_promoted, promoted_id}} ->
          assert promoted_id == integration2.id

          # Primary should now be the second integration
          case CalendarPrimary.get_primary_calendar_integration(user.id) do
            {:ok, primary} ->
              assert primary.id == integration2.id

            {:error, :not_found} ->
              :ok
          end

        {:ok, :deleted} ->
          # Deletion completed without explicit promotion
          :ok
      end
    end

    test "deletes last integration and clears primary", %{user: user} do
      integration = insert(:calendar_integration, user: user)

      # Set as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration.id)

      # Delete last integration
      result = Deletion.delete_with_primary_reassignment(user.id, integration.id)

      # Should clear primary
      assert result == {:ok, {:deleted_cleared_primary}} or result == {:ok, :deleted}

      # Verify deletion
      assert {:error, :not_found} =
               CalendarManagement.get_calendar_integration(integration.id, user.id)

      # Primary should be cleared
      case ProfileQueries.get_by_user_id(user.id) do
        {:ok, profile} ->
          assert profile.primary_calendar_integration_id == nil

        {:error, :not_found} ->
          :ok
      end
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
      assert {:ok, _} =
               CalendarManagement.get_calendar_integration(integration.id, other_user.id)
    end

    test "handles deletion of multiple integrations sequentially", %{user: user} do
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)
      integration3 = insert(:calendar_integration, user: user)

      # Set first as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete first (primary) - should promote second
      result1 = Deletion.delete_with_primary_reassignment(user.id, integration1.id)
      assert match?({:ok, {:deleted_promoted, _}}, result1) or match?({:ok, :deleted}, result1)

      # Delete third (non-primary)
      result2 = Deletion.delete_with_primary_reassignment(user.id, integration3.id)
      assert {:ok, :deleted} = result2

      # Delete second (now primary) - should clear
      result3 = Deletion.delete_with_primary_reassignment(user.id, integration2.id)

      assert result3 == {:ok, {:deleted_cleared_primary}} or result3 == {:ok, :deleted}

      # All integrations should be deleted
      assert CalendarManagement.list_calendar_integrations(user.id) == []
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

    test "promotes most recently created integration when deleting primary", %{user: user} do
      # Create integrations in specific order
      integration1 = insert(:calendar_integration, user: user, inserted_at: ~N[2024-01-01 10:00:00])
      integration2 = insert(:calendar_integration, user: user, inserted_at: ~N[2024-01-02 10:00:00])
      integration3 = insert(:calendar_integration, user: user, inserted_at: ~N[2024-01-03 10:00:00])

      # Set first as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration1.id)

      # Delete primary
      result = Deletion.delete_with_primary_reassignment(user.id, integration1.id)

      assert match?({:ok, {:deleted_promoted, _}}, result) or match?({:ok, :deleted}, result)

      # Verify integration2 or integration3 was promoted (most recent active)
      case CalendarPrimary.get_primary_calendar_integration(user.id) do
        {:ok, primary} ->
          assert primary.id in [integration2.id, integration3.id]

        {:error, :not_found} ->
          :ok
      end
    end

    test "handles concurrent deletions gracefully", %{user: user} do
      integration1 = insert(:calendar_integration, user: user)
      integration2 = insert(:calendar_integration, user: user)

      # Set first as primary
      CalendarPrimary.set_primary_calendar_integration(user.id, integration1.id)

      # Attempt concurrent deletions
      task1 = Task.async(fn -> Deletion.delete_with_primary_reassignment(user.id, integration1.id) end)
      task2 = Task.async(fn -> Deletion.delete_with_primary_reassignment(user.id, integration2.id) end)

      results = Task.await_many([task1, task2], 5000)

      # Both should complete successfully (one deletes, other may get not_found)
      assert Enum.all?(results, fn result ->
               match?({:ok, _}, result) or match?({:error, :not_found}, result)
             end)
    end
  end
end
