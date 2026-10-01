defmodule Tymeslot.Integrations.Calendar.Shared.EventSearch do
  @moduledoc """
  Asks a series of calendars for one event, for the lookups that must tell a
  deleted event from one that lives somewhere else
  (`Provider.fetch_event/2`, `Provider.find_moved_event/2`).
  """

  @doc """
  Calls `ask` with each of `calendars` in turn, until one finds the event.

  The answer is the first `{:ok, events}`, `{:error, :not_found}` only when
  every calendar says the event does not exist, and otherwise the first
  error: one calendar that could not answer leaves the event's absence
  unproven, whatever the others say, unless another one finds it. No
  calendars at all is `{:error, :not_found}`.
  """
  @spec first_found(Enumerable.t(), (term() -> {:ok, list()} | {:error, term()})) ::
          {:ok, list()} | {:error, :not_found} | {:error, term()}
  def first_found(calendars, ask) when is_function(ask, 1) do
    Enum.reduce_while(calendars, {:error, :not_found}, fn calendar, acc ->
      case ask.(calendar) do
        {:ok, _events} = found -> {:halt, found}
        {:error, :not_found} -> {:cont, acc}
        {:error, _reason} = error -> {:cont, unproven(acc, error)}
      end
    end)
  end

  defp unproven({:error, :not_found}, error), do: error
  defp unproven(earlier_error, _error), do: earlier_error
end
