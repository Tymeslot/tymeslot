defmodule Tymeslot.Integrations.Calendar.CalDAV.HostAddressesTest do
  @moduledoc """
  An invitation the host declined on a CalDAV calendar stops holding their
  time, on the sync's normalised events and on availability's live read.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalDAV.HostAddresses
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.ICalParser

  @ics """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//EN
  BEGIN:VEVENT
  UID:declined-invitation
  DTSTART:20261105T100000Z
  DTEND:20261105T110000Z
  ORGANIZER:mailto:organiser@example.com
  ATTENDEE;PARTSTAT=ACCEPTED:mailto:organiser@example.com
  ATTENDEE;PARTSTAT=DECLINED:mailto:Host@Example.com
  ATTENDEE;PARTSTAT=ACCEPTED:mailto:guest@example.com
  END:VEVENT
  END:VCALENDAR
  """

  defp raw_events do
    {:ok, raw_events} = ICalParser.parse(@ics)
    raw_events
  end

  defp normalised(host_addresses) do
    context = %{
      calendar_integration_id: 1,
      provider_calendar_id: "/calendars/host/default/",
      host_addresses: host_addresses,
      synced_at: ~U[2026-11-01 00:00:00Z]
    }

    {:ok, [event]} = ICalNormaliser.normalise_events(raw_events(), context, :caldav)
    event
  end

  describe "for_integration/1" do
    test "names the account's email and an email-shaped login, lowercased" do
      user = insert(:user, email: "Host@Example.com")
      integration = %{insert(:calendar_integration, user: user) | username: "login@example.org"}

      assert Enum.sort(HostAddresses.for_integration(integration)) ==
               ["host@example.com", "login@example.org"]
    end

    test "leaves out a login that is not an email address" do
      user = insert(:user, email: "host@example.com")
      integration = %{insert(:calendar_integration, user: user) | username: "host"}

      assert HostAddresses.for_integration(integration) == ["host@example.com"]
    end
  end

  describe "the sync's normalised events" do
    test "an invitation the host declined is :declined and does not block" do
      event = normalised(["host@example.com"])

      assert event.status == :declined
      refute CalendarEvent.blocking?(event)
    end

    test "another attendee's decline leaves the event the host's to keep" do
      event = normalised(["guest@example.com"])

      assert event.status == :confirmed
      assert CalendarEvent.blocking?(event)
    end
  end

  describe "availability's live read" do
    test "the declined invitation is not busy" do
      busy =
        raw_events()
        |> HostAddresses.mark_declined(["host@example.com"])
        |> ICalNormaliser.expand_occurrences(~U[2026-11-01 00:00:00Z], ~U[2026-11-10 00:00:00Z])
        |> Enum.filter(&CalendarEvent.blocking?/1)

      assert busy == []
    end
  end

  test "a cancelled event the host declined stays cancelled" do
    [raw] = raw_events()
    cancelled = Map.put(raw, :status, "CANCELLED")

    assert [%{status: "CANCELLED"}] =
             HostAddresses.mark_declined([cancelled], ["host@example.com"])
  end
end
