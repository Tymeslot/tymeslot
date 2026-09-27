defmodule Tymeslot.Meetings.AttendeeNotifications.Recipients do
  @moduledoc """
  Who an attendee notification must not reach: the attendees who have
  declined the event, and the user whose integration owns it.

  Google and Outlook both list the organiser as an attendee of events created
  in their own UI, so without the owner's exclusion the person who made the
  change is emailed about it, with an ICS attached. It is deliberately the
  *owner's* address, not the event's `organizer` field: a user can be an
  attendee of someone else's event that syncs into their grid, and changing
  that one must still notify the real organiser.

  Attendee maps come from the cached provider event, so keys and values may
  be atoms (in memory) or strings (after a JSONB round-trip). Addresses are
  compared trimmed and lower-cased.
  """

  alias Tymeslot.Auth.UserQueries

  @doc "The lower-cased addresses `event`'s notifications must skip."
  @spec excluded(map(), pos_integer() | nil) :: MapSet.t(String.t())
  def excluded(event, owner_user_id) do
    MapSet.union(declined_emails(event), owner_emails(owner_user_id))
  end

  @doc "An attendee's address, trimmed and lower-cased; nil when it has none."
  @spec email(map()) :: String.t() | nil
  def email(attendee) do
    case Map.get(attendee, :email) || Map.get(attendee, "email") do
      email when is_binary(email) -> email |> String.trim() |> String.downcase()
      _other -> nil
    end
  end

  defp declined_emails(%{attendees: list}) when is_list(list) do
    for attendee <- list, declined?(attendee), email = email(attendee), email != nil do
      email
    end
    |> MapSet.new()
  end

  defp declined_emails(_event), do: MapSet.new()

  defp owner_emails(id) when is_integer(id) do
    with {:ok, user} <- UserQueries.get_user(id),
         email when is_binary(email) <- user.email do
      MapSet.new([email |> String.trim() |> String.downcase()])
    else
      _no_owner -> MapSet.new()
    end
  end

  defp owner_emails(_id), do: MapSet.new()

  defp declined?(attendee) do
    status = Map.get(attendee, :response_status) || Map.get(attendee, "response_status")
    status in [:declined, "declined"]
  end
end
