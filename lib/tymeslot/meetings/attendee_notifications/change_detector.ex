defmodule Tymeslot.Meetings.AttendeeNotifications.ChangeDetector do
  @moduledoc """
  Pure diffing of two event-shaped maps into a ChangeSummary. All normalisation
  lives here so callers never get to disagree about what counts as a change.
  """

  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary

  @notifiable_fields [:title, :starts_at, :ends_at, :location, :description, :video_link]

  @spec diff(map, map, keyword) :: ChangeSummary.t()
  def diff(old, new, opts) do
    current_sequence = Keyword.fetch!(opts, :current_sequence)

    changed_fields =
      Enum.filter(@notifiable_fields, fn f ->
        field_changed?(f, Map.get(old, f), Map.get(new, f))
      end)

    {added, removed, retained} =
      diff_attendees(Map.get(old, :attendees, []), Map.get(new, :attendees, []))

    next_sequence =
      if changed_fields == [], do: current_sequence, else: current_sequence + 1

    %ChangeSummary{
      changed_fields: changed_fields,
      added_attendees: added,
      removed_attendees: removed,
      retained_attendees: retained,
      next_sequence: next_sequence
    }
  end

  defp field_changed?(:starts_at, a, b), do: not same_instant?(a, b)
  defp field_changed?(:ends_at, a, b), do: not same_instant?(a, b)

  defp field_changed?(:description, a, b),
    do: normalise_description(a) != normalise_description(b)

  defp field_changed?(_field, a, b), do: normalise_text(a) != normalise_text(b)

  defp same_instant?(nil, nil), do: true
  defp same_instant?(nil, _other), do: false
  defp same_instant?(_other, nil), do: false
  defp same_instant?(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b) == :eq

  defp normalise_text(nil), do: ""
  defp normalise_text(v) when is_binary(v), do: v |> String.trim() |> String.downcase()

  defp normalise_description(nil), do: ""

  defp normalise_description(v) when is_binary(v) do
    v
    |> HtmlSanitizeEx.strip_tags()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp diff_attendees(old_list, new_list) do
    old_map = email_map(old_list)
    new_map = email_map(new_list)
    old_emails = MapSet.new(Map.keys(old_map))
    new_emails = MapSet.new(Map.keys(new_map))

    added =
      new_emails |> MapSet.difference(old_emails) |> Enum.map(&new_map[&1])

    removed =
      old_emails |> MapSet.difference(new_emails) |> Enum.map(&old_map[&1])

    retained =
      old_emails |> MapSet.intersection(new_emails) |> Enum.map(&old_map[&1])

    {added, removed, retained}
  end

  defp email_map(list) do
    Map.new(list, fn a ->
      key = a |> Map.get(:email, "") |> String.trim() |> String.downcase()
      {key, a}
    end)
  end
end
