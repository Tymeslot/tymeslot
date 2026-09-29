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

  ## Whose event it is

  `organised_by?/2` answers whether the user organises the event, which
  decides whether deleting it may cancel it for everyone else. It compares
  the event's `organiser` with every address the user is known by there (see
  its docs).
  """

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries

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

  @doc """
  Whether the user `user_id` organises `event`, so that a cancellation sent
  in their name when they delete it is theirs to send.

  The organiser counts as the user when its address is one the user is known
  by on the event's calendar: their Tymeslot address, the account address of
  the integration the event sits on, the integration's login when it is an
  address (a CalDAV login usually is), or the calendar's own id when it is
  one (Google names a secondary calendar, and so the organiser of every
  event created on it, by an address of its own).

  An event naming no organiser counts as the user's own. Every invitation a
  user receives names its organiser (RFC 5546 requires `ORGANIZER` on a
  request), so an event without one was made on the user's own calendar:
  in Tymeslot's grid before its first sync, or in a CalDAV client that does
  not write the line.

  An address the user uses that none of these carries makes the user look
  like a guest of their own event, and the cancellation is then not offered.
  That errs towards telling nobody rather than cancelling someone else's
  event for everyone they invited.
  """
  @spec organised_by?(map(), pos_integer()) :: boolean()
  def organised_by?(event, user_id) do
    case organiser_email(event) do
      nil -> true
      organiser -> MapSet.member?(own_addresses(event, user_id), organiser)
    end
  end

  defp organiser_email(event) do
    case Map.get(event, :organiser) || Map.get(event, "organiser") do
      %{} = organiser -> email(organiser)
      _none -> nil
    end
  end

  defp own_addresses(event, user_id) do
    [calendar_id(event) | integration_addresses(event, user_id)]
    |> Enum.flat_map(&List.wrap(normalise_address(&1)))
    |> MapSet.new()
    |> MapSet.union(owner_emails(user_id))
  end

  defp calendar_id(event), do: Map.get(event, :provider_calendar_id)

  defp integration_addresses(%{calendar_integration_id: id}, user_id)
       when is_integer(id) and is_integer(user_id) do
    case CalendarIntegrationQueries.get_for_user(id, user_id) do
      {:ok, integration} -> [integration.provider_account_email, integration.username]
      {:error, :requires_reencryption, integration} -> [integration.provider_account_email]
      {:error, :not_found} -> []
    end
  end

  defp integration_addresses(_event, _user_id), do: []

  # Only what reads as an address: a calendar id or a login may be anything.
  defp normalise_address(value) when is_binary(value) do
    address = value |> String.trim() |> String.downcase()
    if String.contains?(address, "@"), do: address
  end

  defp normalise_address(_value), do: nil

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
