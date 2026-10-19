defmodule Tymeslot.Integrations.Calendar.ProviderCalendarLabelQueries do
  @moduledoc """
  Rewrites the calendar a cached row is filed under (`provider_calendar_id`).

  The cache upsert never changes that label on an existing row: it is the
  row's identity, and a partial update that omits it must not re-file the
  row. A sync that knows exactly which calendar its rows come from corrects
  it here instead.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @doc """
  Files under `calendar_id` the rows of the integration
  `calendar_integration_id` whose uid is in `uids` or whose label is one of
  `stale_labels`. Returns how many rows changed.
  """
  @spec relabel(pos_integer(), String.t(), [String.t()], [String.t()]) :: non_neg_integer()
  def relabel(calendar_integration_id, calendar_id, uids, stale_labels) do
    {count, _rows} =
      ProviderCalendarEventSchema
      |> where([e], e.calendar_integration_id == ^calendar_integration_id)
      |> where([e], e.provider_calendar_id != ^calendar_id)
      |> where([e], e.uid in ^uids or e.provider_calendar_id in ^stale_labels)
      |> Repo.update_all(set: [provider_calendar_id: calendar_id])

    count
  end
end
