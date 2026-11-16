defmodule Tymeslot.CalendarGrid.SyncProblems do
  @moduledoc """
  Which of the organiser's accounts the calendar's sync banner names, and
  why:

    * `:reauth`: the account needs signing in again;
    * `:unreachable`: its sync has kept failing or been discarded while the
      calendar was open (`failed_ids`, which the caller fills only once a
      failure persists, since one failed attempt is usually retried);
    * `:waiting`: neither, but changes saved here have not reached it yet.

  Each problem carries the titles of the loaded events waiting to be sent
  to that account (a `sync_state` other than `"synced"`), so the banner can
  say "Your change to 'Dentist' is saved here".
  """

  alias Tymeslot.CalendarGrid.EventPayload

  @type kind :: :reauth | :unreachable | :waiting
  @type problem :: %{
          integration_id: pos_integer(),
          account: String.t(),
          kind: kind(),
          pending: [String.t()]
        }

  @spec list([map()], [map()], MapSet.t()) :: [problem()]
  def list(integrations, events, failed_ids) do
    pending = pending_titles(events)

    Enum.flat_map(integrations, fn integration ->
      titles = Map.get(pending, integration.id, [])

      case kind(integration, failed_ids, titles) do
        nil ->
          []

        kind ->
          [
            %{
              integration_id: integration.id,
              account: integration.name,
              kind: kind,
              pending: titles
            }
          ]
      end
    end)
  end

  defp kind(%{needs_reauth: true}, _failed_ids, _titles), do: :reauth

  defp kind(%{id: id}, failed_ids, titles) do
    cond do
      MapSet.member?(failed_ids, id) -> :unreachable
      titles != [] -> :waiting
      true -> nil
    end
  end

  defp pending_titles(events) do
    events
    |> Enum.filter(&(Map.get(&1, :sync_state) not in [nil, "synced"]))
    |> Enum.group_by(&Map.get(&1, :calendar_integration_id), &EventPayload.title/1)
  end
end
