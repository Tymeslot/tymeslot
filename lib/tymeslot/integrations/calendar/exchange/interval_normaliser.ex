defmodule Tymeslot.Integrations.Calendar.Exchange.IntervalNormaliser do
  @moduledoc """
  Turns the busy intervals of a `GetUserAvailability` response into
  `CalendarEvent` structs the cache can hold.

  These are the rows availability is calculated from, and they are the only
  Exchange rows that block time. They exist because the item path cannot see a
  recurring series' later occurrences; see `Exchange.Provider` for the whole
  argument.

  ## Everything here is synthesised

  `GetUserAvailability` answers a start, an end and a busy type, and nothing
  else: no item id, no subject, no change key. So there is no summary, no
  location and no `provider_event_id` to carry, and the uid has to be invented.

  ## The uid, and why it is namespaced

  It is derived from the integration and the interval's own bounds, so it is
  stable across syncs — a uid that changed every cycle would churn the whole
  table — and independent of the interval's position in the response, which a
  new earlier meeting would shift.

  The prefix is load-bearing rather than decorative.
  `Meetings.ExternalCalendarChanges.find_linked_meeting/3` resolves a vanished
  provider event to a Tymeslot meeting **by uid** when no provider event id is
  carried, and cancels the meeting it finds, emailing both parties. A
  synthesised uid that collided with a real meeting's would therefore cancel a
  confirmed booking during routine housekeeping. The `tymeslot:exchange-busy:`
  prefix cannot be produced by anything that shares this integration's uid namespace:
  a Tymeslot meeting uid is a UUID, an EWS `t:UID` is hex, and an EWS item id
  is base64 — none of the three admits a colon. The structural half of the
  same defence is that nothing writing these rows runs the reconciliation at
  all; see `Calendar.Sync.full_refresh_for_role/3`.

  ## Blocking is not implied by the role

  `CalendarEvent.blocking?/1` dispatches on `transparency` and `status` and
  never consults the `role` column, so a busy interval stored without
  `transparency: :opaque` would occupy a `busy_only` row and block nothing —
  the exact silent failure the split exists to prevent. Both are therefore set
  explicitly here rather than left to the struct's defaults.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Exchange.FreeBusy

  @type context :: %{
          calendar_integration_id: integer(),
          synced_at: DateTime.t()
        }

  @uid_prefix "tymeslot:exchange-busy:"

  # `GetUserAvailability` answers for a mailbox rather than a folder, so these
  # rows belong to no calendar the owner selected. The placeholder says so;
  # `CalendarEvent` requires the field.
  @calendar_id "mailbox"

  @doc """
  The namespace every synthesised busy-interval uid carries.

  Public so a test can assert the namespace holds without restating the
  literal, and so a reader looking for "which rows are these?" finds one
  answer.
  """
  @spec uid_prefix() :: String.t()
  def uid_prefix, do: @uid_prefix

  @doc """
  Normalises busy intervals into `CalendarEvent` structs.

  Mirrors `Exchange.EventNormaliser.normalise_events/2`'s shape, and answers
  `{:ok, events}` for the same reason: the caller threads it through a `with`.
  Unlike that function it cannot drop anything — `Exchange.FreeBusy` has
  already refused every interval it could not read, and dropping busy time
  silently is the failure this whole path is built to avoid.
  """
  @spec normalise_intervals([FreeBusy.interval()], context()) :: {:ok, [CalendarEvent.t()]}
  def normalise_intervals(intervals, context) when is_list(intervals) do
    {:ok, Enum.map(intervals, &to_event(&1, context))}
  end

  defp to_event(%{start_at: start_at, end_at: end_at, busy_type: busy_type}, context) do
    CalendarEvent.new!(%{
      uid: uid(context.calendar_integration_id, start_at, end_at, busy_type),
      calendar_integration_id: context.calendar_integration_id,
      provider: :exchange,
      provider_calendar_id: @calendar_id,
      # Left nil deliberately: there is no provider event to point at, and a
      # placeholder would let a deletion signal resolve by it.
      provider_event_id: nil,
      synced_at: context.synced_at,
      all_day: false,
      start_at: start_at,
      end_at: end_at,
      transparency: :opaque,
      status: :confirmed,
      provider_metadata: %{"busy_type" => Atom.to_string(busy_type)}
    })
  end

  # The busy type is part of the key rather than only of the metadata: two
  # intervals sharing bounds but differing in type would otherwise collapse
  # into one row through the upsert's conflict key, and the surviving row's
  # type would depend on ordering.
  defp uid(integration_id, start_at, end_at, busy_type) do
    @uid_prefix <>
      Enum.join(
        [
          integration_id,
          DateTime.to_unix(start_at),
          DateTime.to_unix(end_at),
          busy_type
        ],
        ":"
      )
  end
end
