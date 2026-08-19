defmodule Tymeslot.Notifications.EventTypes do
  @moduledoc """
  The wire names of meeting notification events, defined once.

  Webhooks, Telegram and Slack all publish the same event vocabulary, and each
  carried its own copy of the atom-to-string mapping until this module existed.
  Three copies of a lookup table is where drift lives: an event added to one
  reaches its subscribers under a different name from the others, and the
  fallback (`to_string/1`) turns a missing clause into a plausible-looking
  `"meeting_requested"` rather than an error anyone would notice.

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

  @mapping %{
    meeting_created: "meeting.created",
    meeting_requested: "meeting.requested",
    meeting_declined: "meeting.declined",
    meeting_request_expired: "meeting.request_expired",
    meeting_cancelled: "meeting.cancelled",
    meeting_rescheduled: "meeting.rescheduled"
  }

  @doc "Every event type subscribers may select, as wire strings."
  @spec all() :: [String.t()]
  def all, do: Map.values(@mapping)

  @doc """
  Converts an internal event atom to its wire name.

  Falls back to `to_string/1` for atoms with no entry, matching the behaviour
  the three dispatchers had before they shared this table.
  """
  @spec to_event_type(atom()) :: String.t()
  def to_event_type(atom) when is_atom(atom) do
    Map.get(@mapping, atom, to_string(atom))
  end
end
