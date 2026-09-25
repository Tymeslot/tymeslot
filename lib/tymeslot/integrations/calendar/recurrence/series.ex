defmodule Tymeslot.Integrations.Calendar.Recurrence.Series do
  @moduledoc """
  Whether a calendar event belongs to a repeating series.

  The question is asked by every writer that must not treat one occurrence as
  a standalone event: the calendar grid's move, edit and delete guards
  (`Tymeslot.CalendarGrid.EventMove.ensure_movable/1` and the two built on
  it), and the CalDAV offline queue, which replays writes the grid queued. It
  lives with the calendar integrations rather than with the grid so that the
  queue, which sits below the grid, can ask it without depending upwards.

  An event belongs to a series as the series itself (it carries a repeat
  rule), as one of its expanded occurrences (it names its series), or as an
  occurrence edited on its own. That last one is a VEVENT with a
  `RECURRENCE-ID` and no `RRULE`, so its row carries no repeat rule and names
  no series; only the recurrence id the sync keeps in `provider_metadata`
  marks it.

  Exchange sets none of those fields. Its only series marker is the EWS item
  type, also kept in `provider_metadata`: `RecurringMaster`, `Occurrence` and
  `Exception` all belong to a series.
  """

  alias Tymeslot.Utils.MapKeys

  @doc """
  Whether `event` belongs to a repeating series.

  The recurrence id and the Exchange item type have no columns of their own:
  the sync keeps them in `provider_metadata`, atom-keyed when freshly
  normalised and string-keyed once it has been through the database. Both
  shapes are read here, so a caller may pass a cached row or a normalised
  event.
  """
  @spec member?(map()) :: boolean()
  def member?(event) do
    metadata = Map.get(event, :provider_metadata)

    Enum.any?(
      [
        Map.get(event, :recurrence_rule),
        Map.get(event, :recurring_event_id),
        MapKeys.get_binary(metadata, :recurrence_id)
      ],
      &present?/1
    ) or exchange_series_item?(MapKeys.get_binary(metadata, :calendar_item_type))
  end

  # A server that omits the element leaves no type, which reads as a single
  # item.
  defp exchange_series_item?(nil), do: false
  defp exchange_series_item?("Single"), do: false
  defp exchange_series_item?(_series_type), do: true

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
