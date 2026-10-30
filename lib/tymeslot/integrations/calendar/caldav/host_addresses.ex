defmodule Tymeslot.Integrations.Calendar.CalDAV.HostAddresses do
  @moduledoc """
  Which attendee of a CalDAV event is the host, so that an invitation the
  host declined stops holding their time.

  Google and Outlook mark the signed-in account's own attendee entry; CalDAV
  does not, and a CalDAV integration records no address for its account. The
  host is therefore taken to be whoever answers to the Tymeslot account's
  email, or to the CalDAV login when that is an email address, which covers
  the invitation that reached the address the host signs in with.

  An event the host declined is marked with the status `"DECLINED"` on the
  parsed event, which `ICalNormaliser` maps to `:declined` and
  `CalendarEvent.blocking?/1` reads as free, on the live read and the sync
  alike.
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Repo

  @doc """
  The host's addresses for `integration`, lowercased: the owning account's
  email and the login, each when it is an email address.
  """
  @spec for_integration(map()) :: [String.t()]
  def for_integration(integration) do
    [account_email(integration), Map.get(integration, :username)]
    |> Enum.filter(&email?/1)
    |> Enum.map(&normalise/1)
    |> Enum.uniq()
  end

  @doc """
  `raw_events`, parsed by `ICalParser`, with every event that lists one of
  `addresses` as an attendee who declined marked `"DECLINED"`. A cancelled
  event keeps its own status.
  """
  @spec mark_declined([map()], [String.t()]) :: [map()]
  def mark_declined(raw_events, []), do: raw_events

  def mark_declined(raw_events, addresses) do
    hosts = MapSet.new(addresses)
    Enum.map(raw_events, &mark(&1, hosts))
  end

  defp mark(raw, hosts) do
    if declined_by_host?(raw, hosts) and not cancelled?(raw[:status]),
      do: Map.put(raw, :status, "DECLINED"),
      else: raw
  end

  defp declined_by_host?(raw, hosts) do
    Enum.any?(List.wrap(raw[:attendees]), fn attendee ->
      is_map(attendee) and attendee["status"] == "declined" and email?(attendee["email"]) and
        MapSet.member?(hosts, normalise(attendee["email"]))
    end)
  end

  defp cancelled?(status) when is_binary(status),
    do: String.upcase(String.trim(status)) == "CANCELLED"

  defp cancelled?(_status), do: false

  # An unpersisted integration (an audit's ephemeral target) has no account.
  defp account_email(%CalendarIntegrationSchema{user_id: nil}), do: nil

  defp account_email(%CalendarIntegrationSchema{} = integration) do
    case Repo.preload(integration, :user) do
      %{user: %{email: email}} -> email
      _no_user -> nil
    end
  end

  defp account_email(_integration), do: nil

  defp email?(value), do: is_binary(value) and String.contains?(value, "@")

  defp normalise(address), do: address |> String.trim() |> String.downcase()
end
