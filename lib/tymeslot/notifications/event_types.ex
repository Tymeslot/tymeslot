defmodule Tymeslot.Notifications.EventTypes do
  @moduledoc """
  The wire names for the meeting events every outbound notification channel
  publishes.

  Slack, Telegram and webhooks all subscribe to the same events and all name
  them the same way on the wire, so the mapping lives once here rather than
  three byte-identical times, where the fourth event added would have landed in
  two channels and not the third.
  """

  @events %{
    meeting_created: "meeting.created",
    meeting_cancelled: "meeting.cancelled",
    meeting_rescheduled: "meeting.rescheduled"
  }

  @doc """
  Converts an internal event atom to the event-type string channels store and
  filter on.

  Raises on an atom with no known wire name rather than falling back to
  `to_string/1`: a typo'd or newly-added event atom that silently produces an
  unsubscribable wire name is a worse failure than a crash at the call site.
  """
  @spec to_event_type(atom()) :: String.t()
  def to_event_type(atom) when is_map_key(@events, atom), do: Map.fetch!(@events, atom)

  def to_event_type(atom) when is_atom(atom) do
    raise ArgumentError, "unknown event type: #{inspect(atom)}"
  end

  @doc """
  The wire names every channel may subscribe to, i.e. the values of
  `to_event_type/1`. Channels derive their `@valid_events` list from this so
  adding an event here is what makes it subscribable everywhere.
  """
  @spec all() :: [String.t()]
  def all, do: Map.values(@events)
end
