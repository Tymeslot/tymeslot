defmodule Tymeslot.Notifications.EventTypes do
  @moduledoc """
  The wire names of meeting notification events, defined once.

  Slack, Telegram and webhooks all subscribe to the same events and all name
  them the same way on the wire, so the mapping lives once here rather than
  three byte-identical times, where the fourth event added would have landed in
  two channels and not the third.

  ## What each name promises

    * `meeting.created` — a confirmed booking exists. On a meeting type
      requiring approval this fires when the host approves, not when the
      invitee submits, because that is when the promise becomes true.
    * `meeting.requested` — someone has asked for a slot and it is held
      pending the host's answer.
    * `meeting.declined` — the host refused a request; the slot is free again.
    * `meeting.request_expired` — nobody answered in time; the slot is free
      again.
    * `meeting.cancelled`, `meeting.rescheduled` — unchanged.

  Meeting types without approval never emit the three request events, so
  existing consumers see no change.
  """

  # A keyword list, not a map: dashboards (`Webhooks.available_events/0` and
  # its Slack/Telegram counterparts) list events in this exact order, and a
  # map's enumeration order is an implementation detail, not a guarantee.
  @events [
    meeting_created: "meeting.created",
    meeting_requested: "meeting.requested",
    meeting_declined: "meeting.declined",
    meeting_request_expired: "meeting.request_expired",
    meeting_cancelled: "meeting.cancelled",
    meeting_rescheduled: "meeting.rescheduled"
  ]

  @events_by_atom Map.new(@events)

  @doc """
  Converts an internal event atom to the event-type string channels store and
  filter on.

  Raises on an atom with no known wire name rather than falling back to
  `to_string/1`: a typo'd or newly-added event atom that silently produces an
  unsubscribable wire name is a worse failure than a crash at the call site.
  """
  @spec to_event_type(atom()) :: String.t()
  def to_event_type(atom) when is_map_key(@events_by_atom, atom),
    do: Map.fetch!(@events_by_atom, atom)

  def to_event_type(atom) when is_atom(atom) do
    raise ArgumentError, "unknown event type: #{inspect(atom)}"
  end

  @doc """
  The wire names every channel may subscribe to, i.e. the values of
  `to_event_type/1`, in the authored order above. Channels derive their
  `@valid_events` list from this so adding an event here is what makes it
  subscribable everywhere.
  """
  @spec all() :: [String.t()]
  def all, do: Enum.map(@events, fn {_atom, wire_name} -> wire_name end)
end
