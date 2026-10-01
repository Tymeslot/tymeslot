defmodule Tymeslot.Integrations.Calendar.CalDAV.SchedulingTest do
  @moduledoc """
  Which CalDAV servers Tymeslot will advertise an attendee to.

  The two failure modes this balances are both on record: issue #41, where
  Zimbra ran iTIP for an event carrying an `ATTENDEE` and invited the attendee
  twice over Tymeslot's own notification, and issue #123, where the `CONTACT`
  fallback that fixed it left the organiser's calendar showing a meeting with
  nobody in it.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.Scheduling

  defp client(provider, base_url, calendar_paths \\ []),
    do: %Client{provider: provider, base_url: base_url, calendar_paths: calendar_paths}

  @ox_collection "/caldav/Y2FsOi8vMC8zMg/"

  describe "attendee_mode/1" do
    test "advertises attendees to servers that honour SCHEDULE-AGENT" do
      assert Scheduling.attendee_mode(
               client(:nextcloud, "https://cloud.example.com/remote.php/dav")
             ) == :attendee

      assert Scheduling.attendee_mode(client(:baikal, "https://cal.example.com/dav.php")) ==
               :attendee

      assert Scheduling.attendee_mode(client(:radicale, "https://cal.example.com:5232")) ==
               :attendee

      assert Scheduling.attendee_mode(client(:apple, "https://caldav.icloud.com")) == :attendee
    end

    test "advertises attendees to an unrecognised CalDAV server" do
      assert Scheduling.attendee_mode(client(:caldav, "https://cal.example.org/dav-store/")) ==
               :attendee
    end

    test "withholds them from Zimbra, which ignores the parameter and invites anyway" do
      assert Scheduling.attendee_mode(client(:zimbra, "https://mail.example.com/dav/user@x.com")) ==
               :contact
    end

    # Issue #41's own reporter had Zimbra connected this way, so the provider
    # atom alone would have missed exactly the install the fallback exists for.
    test "withholds them from a Zimbra connected through the generic CalDAV provider" do
      assert Scheduling.attendee_mode(
               client(:caldav, "https://mail.example.com/dav/user@example.com")
             ) == :contact

      assert Scheduling.attendee_mode(client(:caldav, "https://zimbra.example.com/cal/")) ==
               :contact
    end

    test "falls back to advertising when there is no URL to judge" do
      assert Scheduling.attendee_mode(%Client{provider: :caldav, base_url: nil}) == :attendee
    end

    test "lists the organiser too on mailbox.org, which adds its owner otherwise" do
      assert Scheduling.attendee_mode(client(:mailbox_org, "https://dav.mailbox.org")) ==
               :organiser_attendee
    end

    test "recognises mailbox.org connected through the generic CalDAV provider" do
      assert Scheduling.attendee_mode(client(:caldav, "https://dav.mailbox.org/caldav/")) ==
               :organiser_attendee
    end

    test "recognises Open-Xchange on another host by its collection paths" do
      assert Scheduling.attendee_mode(
               client(:caldav, "https://dav.example-hosting.de/caldav/", [@ox_collection])
             ) == :organiser_attendee
    end

    test "recognises it from a collection among the writable paths alone" do
      client = %Client{
        provider: :caldav,
        base_url: "https://dav.example-hosting.de/",
        calendar_paths: [],
        writable_calendar_paths: [@ox_collection]
      }

      assert Scheduling.attendee_mode(client) == :organiser_attendee
    end

    # Server-issued collection ids outrank the Zimbra guess a principal URL,
    # typed as the base URL, would otherwise attract.
    test "trusts the collection paths over a URL that looks like Zimbra's" do
      assert Scheduling.attendee_mode(
               client(:caldav, "https://dav.example.net/principals/users/3", [@ox_collection])
             ) == :organiser_attendee
    end

    test "keeps the Zimbra provider on CONTACT whatever its paths look like" do
      assert Scheduling.attendee_mode(
               client(:zimbra, "https://mail.example.com/dav/user@x.com", [@ox_collection])
             ) == :contact
    end
  end
end
