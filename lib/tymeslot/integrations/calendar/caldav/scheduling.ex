defmodule Tymeslot.Integrations.Calendar.CalDAV.Scheduling do
  @moduledoc """
  Decides how a CalDAV server is told who a Tymeslot event is with.

  RFC 6638 lets a client opt out of server-side scheduling by tagging its
  `ATTENDEE` properties `SCHEDULE-AGENT=CLIENT`: the server then stores the
  attendee without mailing them an iTIP invitation, which is exactly what
  Tymeslot wants, because it sends its own notification with its own branding
  and its own reschedule and cancellation links.

  Most servers honour that. sabre/dav — Nextcloud, Baikal, ownCloud — skips
  scheduling for such an attendee in `ITip\\Broker`, with the rule enabled by
  default; Radicale implements no scheduling at all; Apple co-authored the RFC.
  Zimbra is the exception on record: it strips the parameter and runs iTIP for
  any event carrying an `ATTENDEE`, so a single booking reached the attendee
  three times (issue #41). Issue #123 is the other side of that trade — an
  event with no `ATTENDEE` shows one participant in the organiser's calendar,
  and the organiser's own client can never send an update to whoever booked.

  So attendees are advertised everywhere except Zimbra, which keeps the
  `CONTACT` fallback (RFC 5545 §3.8.4.2): the same name and address, carried
  outside the iTIP model.

  A Zimbra reached through the generic CalDAV provider counts as Zimbra.
  `ServerDetector` recognises it from the URL alone, which is how the original
  report was configured, and an unrecognised server that is really Zimbra is
  the one case worth erring towards: `:contact` is what every CalDAV server
  gets today, so a wrong guess leaves that user exactly where they are rather
  than spamming the people who book with them.

  ## Open-Xchange

  Open-Xchange, the server behind mailbox.org, insists that the owner of the
  calendar an event is stored in is one of its attendees, and adds them when
  the event does not list them (issue #151). It recognises the owner by any
  address on their account, aliases included, but writes the one it adds
  under the account's primary address. A user whose Tymeslot address is an
  alias, or a custom domain, on that account therefore saw their login
  address appear beside the booker, on the server and in every client that
  syncs from it, whether the event carried the booker as an `ATTENDEE`, as a
  `CONTACT`, or not at all.

  `{:organiser_attendee, addresses}` lists the account's owner as an attendee, so the
  server finds them already present and adds nobody. The server recognises its
  owner only by an address in the account's `calendar-user-address-set`,
  matched on the `mailto:` itself (an `EMAIL=` parameter is rewritten, and
  `SENT-BY` changes nothing), so which address that line carries depends on
  the organiser's:

    * an address on the account, the login or an alias the account lists:
      the organiser themselves, as the chair, and the event shows exactly the
      organiser and whoever booked;
    * any other address, typically a custom domain the account does not list
      as its own: the account's preferred address, the one the server would
      have added, which `ORGANIZER` carries too. Listing the organiser
      instead, as the first fix for #151 did, left the owner added beside
      them, which put the organiser in the event twice; keeping their address
      as `ORGANIZER` alone, as the second did, still showed them under two
      addresses, and the server, taking the event for an invitation from
      someone else, silently ignored every later change to its guests. The
      organiser's own copy now shows them once, under the account's address,
      while the booker's invitation, which Tymeslot sends itself, keeps theirs.

  Mailbox.org lists its own aliases in that set, but by the report in #151
  not a custom-domain address added to the account, so the second case is
  the usual one for an organiser on their own domain. Measured against a live account on
  2026-10-19: no event shape keeps the account's address out of an event that
  has an organiser or any attendee.

  The server also silently drops an update that names a different
  `ORGANIZER` from the stored one, so `ORGANIZER` is written on create only:
  the patcher never touches it, and an update with no cached copy reads the
  server's first (`CalDAV.Events.update_calendar_event/5`). Events created
  before the change keep the organiser they were created with.

  The mode carries the addresses `Discovery.calendar_user_addresses/1`
  answers, read per write; a failed lookup carries none, and the organiser is
  then listed as in the first case, which is right whenever their address is
  on the account.

  Recognised by the provider (`:mailbox_org`), by the host, or by the
  collection paths discovery returned (`ServerDetector.open_xchange_path?/1`),
  so an Open-Xchange server under another domain, connected through generic
  CalDAV, is treated alike. The collection paths are checked before the URL:
  they are server-issued, so they outrank a guess from a URL a user typed,
  including the Zimbra guess an Open-Xchange principal URL
  (`/principals/users/3`) would otherwise attract.
  """

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.Discovery
  alias Tymeslot.Integrations.Calendar.CalDAV.ServerDetector

  require Logger

  @typedoc """
  `{:organiser_attendee, addresses}` carries the account's own addresses, the
  preferred one first, or `[]` when they could not be read.
  """
  @type mode :: :attendee | {:organiser_attendee, [String.t()]} | :contact

  @doc """
  Returns the attendee mode for `client`.

  `:contact` for Zimbra, whether it was connected through the Zimbra provider
  or through generic CalDAV against a recognisably Zimbra URL;
  `{:organiser_attendee, addresses}` for Open-Xchange (see the moduledoc),
  which asks the server for the account's addresses; `:attendee` for every
  other CalDAV server. Called on the write path only, so the lookup costs a
  request per write to an Open-Xchange calendar and nothing anywhere else.

  Matches the client structurally, as the rest of the CalDAV layer reads it:
  there is no malformed input to reject here, only a server to classify, and
  `:attendee` is the right answer for one carrying neither field.
  """
  @spec attendee_mode(Client.t()) :: mode()
  def attendee_mode(client) when is_map(client) do
    case server(client) do
      :zimbra -> :contact
      :open_xchange -> {:organiser_attendee, owner_addresses(client)}
      _other -> :attendee
    end
  end

  @doc """
  Whether `client` writes to an Open-Xchange server, recognised as
  `attendee_mode/1` recognises it, without asking the server anything.
  """
  @spec open_xchange?(Client.t()) :: boolean()
  def open_xchange?(client) when is_map(client), do: server(client) == :open_xchange

  @doc """
  The address an `{:organiser_attendee, addresses}` event lists for its
  owner, given the organiser's (see the moduledoc): the organiser's own when
  it is on the account or the account's addresses are unknown, otherwise the
  account's preferred one. `nil` without an organiser.
  """
  @spec owner_attendee_address(String.t() | nil, [String.t()]) :: String.t() | nil
  def owner_attendee_address(organiser, addresses) when is_binary(organiser) do
    organiser = String.trim(organiser)

    cond do
      organiser == "" -> nil
      addresses == [] or String.downcase(organiser) in addresses -> organiser
      true -> hd(addresses)
    end
  end

  def owner_attendee_address(_organiser, _addresses), do: nil

  defp owner_addresses(client) do
    case Discovery.calendar_user_addresses(client) do
      {:ok, addresses} ->
        addresses

      {:error, reason} ->
        Logger.warning("Could not read the CalDAV account's own addresses",
          reason: LogFormat.reason(reason),
          provider: Map.get(client, :provider)
        )

        []
    end
  end

  defp server(%{provider: :zimbra}), do: :zimbra
  defp server(%{provider: :mailbox_org}), do: :open_xchange

  defp server(client) do
    if Enum.any?(collection_paths(client), &ServerDetector.open_xchange_path?/1),
      do: :open_xchange,
      else: url_server(client)
  end

  defp url_server(%{base_url: base_url}) when is_binary(base_url) do
    case ServerDetector.detect_from_url(base_url) do
      :mailbox_org -> :open_xchange
      server -> server
    end
  end

  defp url_server(_client), do: :generic

  defp collection_paths(client) do
    Enum.filter(
      List.wrap(Map.get(client, :calendar_paths)) ++
        List.wrap(Map.get(client, :writable_calendar_paths)),
      &is_binary/1
    )
  end
end
