defmodule Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState do
  @moduledoc """
  Serialises and restores the last-successfully-notified snapshot for an event.
  Stored as a jsonb column (`last_notified_state`) on `meetings` and `provider_calendar_events`.
  """

  @fields [
    :title,
    :starts_at,
    :ends_at,
    :start_date,
    :end_date,
    :location,
    :description,
    :video_link
  ]

  @spec serialise(map, [map]) :: map
  def serialise(event, attendees) when is_map(event) and is_list(attendees) do
    @fields
    |> Map.new(fn
      field when field in [:starts_at, :ends_at] ->
        {Atom.to_string(field), format_datetime(Map.get(event, field))}

      field when field in [:start_date, :end_date] ->
        {Atom.to_string(field), format_date(Map.get(event, field))}

      field ->
        {Atom.to_string(field), normalise_text(Map.get(event, field))}
    end)
    |> Map.put("attendees", normalise_emails(attendees))
  end

  @doc """
  Whether nothing has ever been recorded for the event, so that whatever it
  was before is unknown rather than empty. See `to_event/2`.
  """
  @spec empty?(map) :: boolean
  def empty?(state) when is_map(state), do: map_size(state) == 0

  @spec to_event(map) :: map
  def to_event(state) when is_map(state) do
    %{
      title: Map.get(state, "title", ""),
      starts_at: parse_datetime(Map.get(state, "starts_at")),
      ends_at: parse_datetime(Map.get(state, "ends_at")),
      start_date: parse_date(Map.get(state, "start_date")),
      end_date: parse_date(Map.get(state, "end_date")),
      location: Map.get(state, "location", ""),
      description: Map.get(state, "description", ""),
      video_link: empty_to_nil(Map.get(state, "video_link", "")),
      attendees: restore_attendees(Map.get(state, "attendees", []))
    }
  end

  @doc """
  Restores the baseline to diff `current` against, filling in what an event
  that has never been notified cannot know.

  Nothing seeds `last_notified_state` on create or on sync, so every event is
  born with `%{}` and only gains a baseline once this pipeline has dispatched
  for it. An empty baseline therefore does not mean "nobody knows about this
  event": it means Tymeslot has not yet recorded what they were told. The
  people on the event today are the people whichever path created it already
  invited, so they are **retained** rather than newly added, and the first
  edit notifies exactly who the second one would.

  Only the attendee list is carried over. The fields stay empty, so every
  populated one still reads as changed and the diff stays non-empty, which is
  what makes the notification go out at all; the update email simply has no
  "before" value to show for them, which is why the worker flags such a
  dispatch as a first notification (see `empty?/1`).
  """
  @spec to_event(map, map) :: map
  def to_event(state, current) when is_map(state) and map_size(state) == 0 and is_map(current) do
    %{to_event(state) | attendees: Map.get(current, :attendees, [])}
  end

  def to_event(state, _current) when is_map(state), do: to_event(state)

  defp normalise_text(nil), do: ""
  defp normalise_text(value) when is_binary(value), do: String.trim(value)

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp format_datetime(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)

  defp parse_date(iso) when is_binary(iso) do
    case Date.from_iso8601(iso) do
      {:ok, date} -> date
      _error -> nil
    end
  end

  defp parse_date(_missing), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _error -> nil
    end
  end

  defp normalise_emails(attendees) do
    attendees
    |> Enum.map(&(&1 |> Map.get(:email, "") |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.sort()
    |> Enum.uniq()
  end

  # `serialise/2` stores plain email strings, but the backfill in migration
  # `20260415154744` copied the `attendees` jsonb column across verbatim, so
  # rows that predate the column carry attendee objects instead. Both shapes
  # have to restore to the `%{email: binary}` maps ChangeDetector expects;
  # anything else would reach `String.trim/1` as a map and crash the job.
  defp restore_attendees(attendees) when is_list(attendees) do
    attendees
    |> Enum.map(&restore_email/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&%{email: &1})
  end

  defp restore_attendees(_other), do: []

  defp restore_email(email) when is_binary(email), do: email
  defp restore_email(%{"email" => email}) when is_binary(email), do: email
  defp restore_email(%{email: email}) when is_binary(email), do: email
  defp restore_email(_other), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v
end
