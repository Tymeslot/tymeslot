defmodule Tymeslot.Meetings.CalendarEventLink do
  @moduledoc """
  The single expression of "this cached provider event is that meeting".

  A booking written back to a connected calendar comes back through sync as a
  cached provider event, so every consumer that shows both lists has to know
  which cached row mirrors which meeting: the grid drops the booking
  projection, the agenda drops the provider copy, and the sync's post-commit
  pass needs the meeting to reconcile an external time change against.

  The two sides do not agree on one identifier, because `provider_event_id`
  means different things per provider family:

  | Provider | `meetings` | `provider_calendar_events` |
  |---|---|---|
  | Google, Outlook | provider event id | provider event id |
  | CalDAV family | *unset* — the mapping lives in `uid` | the event's href |

  So a join on `provider_event_id` alone silently matches nothing for every
  CalDAV-family integration, and one on `uid` alone matches nothing for Google
  and Outlook (whose cached `uid` is the provider's own iCalUID, not the UID
  Tymeslot generated). The rule that holds for both: **two records describe the
  same event when they share any non-blank identifier.** Identifiers are
  compared within a single calendar integration, and the values are distinct
  enough across namespaces (hrefs, provider ids, `…@tymeslot.com` UIDs) that a
  cross-match cannot occur in practice.

  Callers reach this through the `Tymeslot.Meetings` context.
  """

  @identity_fields [:provider_event_id, :uid]

  @doc """
  Returns the non-blank identifiers of a meeting or a calendar event.

  Accepts any struct or map carrying `:provider_event_id` and/or `:uid` —
  meetings, cached provider events, `CalendarEvent` structs, and the grid's
  `BookingEvent` projections all qualify.
  """
  @spec identifiers(map()) :: [String.t()]
  def identifiers(record) when is_map(record) do
    @identity_fields
    |> Enum.map(&Map.get(record, &1))
    |> Enum.reject(&blank_identifier?/1)
  end

  @doc """
  Collects every identifier across `records` into one set, for matching many
  records against many without an N×M scan.
  """
  @spec identifier_set(Enumerable.t()) :: MapSet.t(String.t())
  def identifier_set(records) do
    records
    |> Enum.flat_map(&identifiers/1)
    |> MapSet.new()
  end

  @doc """
  Whether `record` shares an identifier with the set built from the other side
  of the join.
  """
  @spec linked?(map(), MapSet.t(String.t())) :: boolean()
  def linked?(record, %MapSet{} = identifier_set) do
    record
    |> identifiers()
    |> Enum.any?(&MapSet.member?(identifier_set, &1))
  end

  @doc """
  Whether `value` is unusable as an identifier: absent, or blank once trimmed.

  Exposed so that callers holding bare identifier values rather than whole
  records (a query filtering its argument list, say) apply the same rule.
  """
  @spec blank_identifier?(term()) :: boolean()
  def blank_identifier?(nil), do: true
  def blank_identifier?(value) when is_binary(value), do: String.trim(value) == ""
  def blank_identifier?(_value), do: false
end
