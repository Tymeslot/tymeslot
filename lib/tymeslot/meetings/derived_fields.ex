defmodule Tymeslot.Meetings.DerivedFields do
  @moduledoc """
  The fields a meeting changeset fills in from the others rather than from
  the caller: the calendar identity, the end time the calendar last saw, and
  the duration. Applied by `Tymeslot.Meetings.MeetingSchema`'s changesets.
  """

  import Ecto.Changeset, only: [get_change: 2, get_field: 2, put_change: 3]

  alias Ecto.Changeset
  alias Ecto.UUID

  @doc """
  Fills in every derived field the changeset does not already carry.
  """
  @spec put(Changeset.t()) :: Changeset.t()
  def put(changeset) do
    changeset
    |> ensure_calendar_uid()
    |> ensure_seen_calendar_end()
    |> calculate_duration()
  end

  # A new meeting gets its own calendar identity, generated independently of
  # `uid` so that nothing readable in a calendar leads back to the capability.
  # A UUID, like `uid`, because callers tell a Tymeslot-minted identifier from
  # one a provider assigned by that shape (`CalendarEventSync`'s legacy
  # mapping check, the Exchange busy-interval namespace). An existing meeting
  # already has one and keeps it: its event is keyed by it, and a new value
  # would orphan that event.
  defp ensure_calendar_uid(changeset) do
    case get_field(changeset, :calendar_uid) do
      nil -> put_change(changeset, :calendar_uid, UUID.generate())
      _present -> changeset
    end
  end

  defp ensure_seen_calendar_end(%Changeset{data: %{__meta__: %{state: :built}}} = cs),
    do: put_change(cs, :seen_calendar_end_time, get_field(cs, :end_time))

  defp ensure_seen_calendar_end(changeset), do: changeset

  # Only when the caller gave no duration of its own.
  defp calculate_duration(changeset) do
    case {get_change(changeset, :duration), get_field(changeset, :start_time),
          get_field(changeset, :end_time)} do
      {nil, %DateTime{} = start_time, %DateTime{} = end_time} ->
        put_change(changeset, :duration, DateTime.diff(end_time, start_time, :minute))

      _given_or_incomplete ->
        changeset
    end
  end
end
