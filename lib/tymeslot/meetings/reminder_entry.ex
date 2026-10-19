defmodule Tymeslot.Meetings.ReminderEntry do
  @moduledoc """
  The shape of one entry in a meeting's `reminders_sent` column, read in one
  place: which reminder an entry is for, and whom it went to.

  An entry names its reminder by `value` and `unit`, and records
  `organizer_sent` and `attendee_sent`. Keys may be strings (as stored) or
  atoms (a struct built in memory). An entry written before per-recipient
  tracking carries no flags; it exists because the reminder fired, so it is
  read as sent to both rather than guessed at, and an old row never triggers
  a fresh send.
  """

  @type entry :: map()
  @type status :: %{organizer: boolean(), attendee: boolean()}

  @doc "The entry in `entries` for the reminder `value` `unit`, or nil."
  @spec find([entry()] | nil, term(), term()) :: entry() | nil
  def find(entries, value, unit),
    do: entries |> List.wrap() |> Enum.find(&for_reminder?(&1, value, unit))

  @doc "Whether `entry` is for the reminder `value` `unit`."
  @spec for_reminder?(term(), term(), term()) :: boolean()
  def for_reminder?(%{"value" => v, "unit" => u}, value, unit), do: v == value and u == unit
  def for_reminder?(%{value: v, unit: u}, value, unit), do: v == value and u == unit
  def for_reminder?(_entry, _value, _unit), do: false

  @doc """
  Whom the reminder `value` `unit` has gone to, from `entries`: neither when
  there is no entry for it.
  """
  @spec status([entry()] | nil, term(), term()) :: status()
  def status(entries, value, unit) do
    case find(entries, value, unit) do
      nil -> %{organizer: false, attendee: false}
      entry -> %{organizer: sent?(entry, :organizer), attendee: sent?(entry, :attendee)}
    end
  end

  @doc "Whether `entry` records the reminder as sent to `recipient`."
  @spec sent?(entry(), :organizer | :attendee) :: boolean()
  def sent?(entry, :organizer), do: flag(entry, "organizer_sent", :organizer_sent)
  def sent?(entry, :attendee), do: flag(entry, "attendee_sent", :attendee_sent)

  defp flag(entry, string_key, atom_key) do
    case entry do
      %{^string_key => sent} when is_boolean(sent) -> sent
      %{^atom_key => sent} when is_boolean(sent) -> sent
      _legacy -> true
    end
  end
end
