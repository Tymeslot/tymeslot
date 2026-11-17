defmodule Tymeslot.Meetings.AttendeeName do
  @moduledoc """
  The name to show for a meeting's attendee beside their address.

  A meeting the host manages (`Tymeslot.Meetings.HostManaged`) created
  without a main participant stores its first guest's address as the
  attendee's name, since the guest gave none. Shown as a name, that address
  appears twice ("a@x <a@x>"), so wherever the attendee is written with a
  name and an address, this is the name: `nil` when there is none or it is
  only the address again. Callers then show the address alone.
  """

  @doc """
  The attendee's name, or `nil` when it is blank or the attendee's address
  (compared trimmed and case-insensitively). Takes a meeting or any map with
  `attendee_name` and `attendee_email`, such as an appointment's details.
  """
  @spec display_name(map()) :: String.t() | nil
  def display_name(meeting) do
    name = meeting |> Map.get(:attendee_name) |> trimmed()

    cond do
      name == nil -> nil
      normalise(name) == normalise(trimmed(Map.get(meeting, :attendee_email))) -> nil
      true -> name
    end
  end

  defp trimmed(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_value), do: nil

  defp normalise(nil), do: nil
  defp normalise(text), do: String.downcase(text)
end
