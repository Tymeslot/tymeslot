defmodule Tymeslot.Meetings.AttendeeNotifications.LastNotifiedState do
  @moduledoc """
  Serialises and restores the last-successfully-notified snapshot for an event.
  Stored as a jsonb column (`last_notified_state`) on `meetings` and `provider_calendar_events`.
  """

  @fields [:title, :starts_at, :ends_at, :location, :description, :video_link]

  @spec serialise(map, [map]) :: map
  def serialise(event, attendees) when is_map(event) and is_list(attendees) do
    @fields
    |> Map.new(fn
      field when field in [:starts_at, :ends_at] ->
        {Atom.to_string(field), format_datetime(Map.get(event, field))}

      field ->
        {Atom.to_string(field), normalise_text(Map.get(event, field))}
    end)
    |> Map.put("attendees", normalise_emails(attendees))
  end

  @spec to_event(map) :: map
  def to_event(state) when is_map(state) do
    %{
      title: Map.get(state, "title", ""),
      starts_at: parse_datetime(Map.get(state, "starts_at")),
      ends_at: parse_datetime(Map.get(state, "ends_at")),
      location: Map.get(state, "location", ""),
      description: Map.get(state, "description", ""),
      video_link: empty_to_nil(Map.get(state, "video_link", "")),
      attendees: Enum.map(Map.get(state, "attendees", []), &%{email: &1})
    }
  end

  defp normalise_text(nil), do: ""
  defp normalise_text(value) when is_binary(value), do: String.trim(value)

  defp format_datetime(nil), do: nil

  defp format_datetime(%DateTime{} = dt),
    do: dt |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp format_datetime(%NaiveDateTime{} = ndt),
    do: ndt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

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

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(v), do: v
end
