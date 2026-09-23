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
  """

  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.ServerDetector

  @type mode :: :attendee | :contact

  @doc """
  Returns the attendee mode for `client`.

  `:contact` for Zimbra, whether it was connected through the Zimbra provider
  or through generic CalDAV against a recognisably Zimbra URL; `:attendee` for
  every other CalDAV server.

  Matches the client structurally, as the rest of the CalDAV layer reads it:
  there is no malformed input to reject here, only a server to classify, and
  `:attendee` is the right answer for one carrying neither field.
  """
  @spec attendee_mode(Client.t()) :: mode()
  def attendee_mode(%{provider: :zimbra}), do: :contact

  def attendee_mode(%{base_url: base_url}) when is_binary(base_url) do
    case ServerDetector.detect_from_url(base_url) do
      :zimbra -> :contact
      _other -> :attendee
    end
  end

  def attendee_mode(client) when is_map(client), do: :attendee
end
