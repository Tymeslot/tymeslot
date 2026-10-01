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

  `:organiser_attendee` lists the organiser as an attendee as well, which
  RFC 5545 permits and most calendar clients do anyway. The server then finds
  its owner already present, under the address the organiser chose, and adds
  nobody. It cannot help an organiser address the account does not own: the
  server adds its owner then too, which is its rule and not Tymeslot's to
  override.

  Recognised by the provider (`:mailbox_org`), by the host, or by the
  collection paths discovery returned (`ServerDetector.open_xchange_path?/1`),
  so an Open-Xchange server under another domain, connected through generic
  CalDAV, is treated alike. The collection paths are checked before the URL:
  they are server-issued, so they outrank a guess from a URL a user typed,
  including the Zimbra guess an Open-Xchange principal URL
  (`/principals/users/3`) would otherwise attract.
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.ServerDetector

  @type mode :: :attendee | :organiser_attendee | :contact

  @doc """
  Returns the attendee mode for `client`.

  `:contact` for Zimbra, whether it was connected through the Zimbra provider
  or through generic CalDAV against a recognisably Zimbra URL;
  `:organiser_attendee` for Open-Xchange (see the moduledoc); `:attendee` for
  every other CalDAV server.

  Matches the client structurally, as the rest of the CalDAV layer reads it:
  there is no malformed input to reject here, only a server to classify, and
  `:attendee` is the right answer for one carrying neither field.
  """
  @spec attendee_mode(Client.t()) :: mode()
  def attendee_mode(client) when is_map(client) do
    case server(client) do
      :zimbra -> :contact
      :open_xchange -> :organiser_attendee
      _other -> :attendee
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
