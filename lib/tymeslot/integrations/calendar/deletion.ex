defmodule Tymeslot.Integrations.Calendar.Deletion do
  @moduledoc """
  Business logic for deleting an integration while maintaining the primary
  calendar invariant (promote another or clear primary).
  """

  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  @type user_id :: pos_integer()

  @doc """
  Delete an integration. If it is the primary one, promote another if available,
  otherwise clear primary.

  Returns:
    {:ok, :deleted}
    {:ok, {:deleted_promoted, promoted_id}}
    {:ok, {:deleted_cleared_primary}}
    {:error, :not_found | term()}
  """
  @spec delete_with_primary_reassignment(user_id(), pos_integer()) ::
          {:ok, :deleted | {:deleted_promoted, pos_integer()} | {:deleted_cleared_primary}}
          | {:error, term()}
  def delete_with_primary_reassignment(user_id, integration_id)
      when is_integer(user_id) and is_integer(integration_id) do
    with {:ok, integration} <-
           CalendarManagement.get_calendar_integration(integration_id, user_id),
         promoted_result <- maybe_handle_primary(user_id, integration),
         {:ok, _result} <- clear_references_and_delete(integration) do
      case promoted_result do
        {:promoted, next_id} -> {:ok, {:deleted_promoted, next_id}}
        :cleared -> {:ok, {:deleted_cleared_primary}}
        :unchanged -> {:ok, :deleted}
      end
    else
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_handle_primary(user_id, integration) do
    with {:ok, %{id: primary_id}} <- CalendarPrimary.get_primary_calendar_integration(user_id),
         true <- primary_id == integration.id do
      promote_next_or_clear(user_id, integration.id)
    else
      _not_primary -> :unchanged
    end
  end

  defp clear_references_and_delete(integration) do
    Repo.transaction(fn ->
      MeetingTypeQueries.clear_calendar_references(integration.id)

      case CalendarManagement.delete_calendar_integration(integration) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp promote_next_or_clear(user_id, exclude_id) do
    others =
      Enum.reject(CalendarManagement.list_calendar_integrations(user_id), &(&1.id == exclude_id))

    case others do
      [next | _rest] ->
        case CalendarPrimary.set_primary_calendar_integration(user_id, next.id) do
          {:ok, _profile} -> {:promoted, next.id}
          _error -> :unchanged
        end

      [] ->
        case ProfileQueries.clear_primary_calendar_integration(user_id) do
          {:ok, _profile} -> :cleared
          _error -> :unchanged
        end
    end
  end
end
