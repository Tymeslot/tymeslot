defmodule Tymeslot.Integrations.Calendar.Deletion do
  @moduledoc """
  Business logic for deleting an integration while maintaining the primary
  calendar invariant (promote another or clear primary).

  ## Why mirror teardown runs before anything else

  A disconnected calendar takes its sync links with it —
  `on_delete: :delete_all` sees to the rows — but a link's *placeholders* are
  events on a provider, and the mapping rows about to be cascaded away hold the
  only record of which events those are. Dropping them first leaves busy blocks
  on the organiser's other calendars that nothing owns and nothing will ever
  clean up, so `SyncLink.Teardown` runs first and the disconnect is abandoned
  if it cannot finish.

  Both directions matter. The integration may be a link's *target*, holding the
  placeholders itself, or its *source*, having caused placeholders on calendars
  that are staying connected — those are the ones with nobody left to remove
  them.

  It runs outside `clear_references_and_delete/1` deliberately: that is a
  `Repo.transaction`, and teardown makes provider calls. Holding a database
  transaction open across a round trip to Google would put connection-pool
  starvation and a slow calendar server on the same fuse.
  """

  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.SyncLink.Teardown
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.CalendarPrimary
  alias Tymeslot.MeetingTypes.MeetingTypeQueries
  alias Tymeslot.Profiles.ProfileQueries
  alias Tymeslot.Repo

  @type user_id :: pos_integer()

  @doc """
  Delete an integration. If it is the primary one, promote another if available,
  otherwise clear primary.

  Every mirror placeholder either end of the integration's sync links produced
  is withdrawn from its provider first; a placeholder that cannot be withdrawn
  aborts the deletion and leaves the integration connected, because deleting it
  would cascade away the only record of where that placeholder is.

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
         :ok <- Teardown.tear_down_for_integration(integration.id, user_id),
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
      user_id
      |> CalendarManagement.list_calendar_integrations()
      |> Enum.reject(&(&1.id == exclude_id or ProviderConfig.subscription?(&1.provider)))

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
