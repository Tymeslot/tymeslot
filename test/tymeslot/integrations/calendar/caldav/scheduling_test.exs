defmodule Tymeslot.Integrations.Calendar.CalDAV.SchedulingTest do
  @moduledoc """
  Which CalDAV servers Tymeslot will advertise an attendee to.

  The two failure modes this balances are both on record: issue #41, where
  Zimbra ran iTIP for an event carrying an `ATTENDEE` and invited the attendee
  twice over Tymeslot's own notification, and issue #123, where the `CONTACT`
  fallback that fixed it left the organiser's calendar showing a meeting with
  nobody in it.
  """
  use Tymeslot.HttpTransportCase, async: false

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.CalDAVTestHelpers
  alias Tymeslot.Integrations.Calendar.CalDAV.Client
  alias Tymeslot.Integrations.Calendar.CalDAV.Scheduling

  @addresses ["login@mailbox.org", "alias@mailbox.org"]

  # An Open-Xchange answer reads the account's own addresses, which every
  # test is given; the other servers never ask.
  setup do
    ReqTest.stub(:tymeslot_http, &CalDAVTestHelpers.answer_address_lookup(&1, @addresses))
    :ok
  end

  defp client(provider, base_url, calendar_paths \\ []) do
    %Client{
      provider: provider,
      base_url: base_url,
      username: "user",
      password: "pass",
      calendar_paths: calendar_paths
    }
  end

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
               {:organiser_attendee, @addresses}
    end

    test "recognises mailbox.org connected through the generic CalDAV provider" do
      assert Scheduling.attendee_mode(client(:caldav, "https://dav.mailbox.org/caldav/")) ==
               {:organiser_attendee, @addresses}
    end

    test "recognises Open-Xchange on another host by its collection paths" do
      assert Scheduling.attendee_mode(
               client(:caldav, "https://dav.example-hosting.de/caldav/", [@ox_collection])
             ) == {:organiser_attendee, @addresses}
    end

    test "recognises it from a collection among the writable paths alone" do
      client = %Client{
        provider: :caldav,
        base_url: "https://dav.example-hosting.de/",
        username: "user",
        password: "pass",
        calendar_paths: [],
        writable_calendar_paths: [@ox_collection]
      }

      assert Scheduling.attendee_mode(client) == {:organiser_attendee, @addresses}
    end

    # Server-issued collection ids outrank the Zimbra guess a principal URL,
    # typed as the base URL, would otherwise attract.
    test "trusts the collection paths over a URL that looks like Zimbra's" do
      assert Scheduling.attendee_mode(
               client(:caldav, "https://dav.example.net/principals/users/3", [@ox_collection])
             ) == {:organiser_attendee, @addresses}
    end

    test "keeps the Zimbra provider on CONTACT whatever its paths look like" do
      assert Scheduling.attendee_mode(
               client(:zimbra, "https://mail.example.com/dav/user@x.com", [@ox_collection])
             ) == :contact
    end

    test "carries no addresses when the account will not say which are its own" do
      ReqTest.stub(:tymeslot_http, &Conn.send_resp(&1, 500, ""))

      assert Scheduling.attendee_mode(client(:mailbox_org, "https://dav.mailbox.org")) ==
               {:organiser_attendee, []}
    end
  end

  describe "owner_attendee_address/2" do
    test "is the organiser when the account owns their address, whatever its case" do
      assert Scheduling.owner_attendee_address("Alias@mailbox.org", @addresses) ==
               "Alias@mailbox.org"
    end

    test "is the account's preferred address for an organiser it does not own" do
      assert Scheduling.owner_attendee_address("me@custom.example", @addresses) ==
               "login@mailbox.org"
    end

    test "is the organiser when the account's addresses are unknown" do
      assert Scheduling.owner_attendee_address("me@custom.example", []) == "me@custom.example"
    end

    test "is nobody without an organiser" do
      assert Scheduling.owner_attendee_address(nil, @addresses) == nil
      assert Scheduling.owner_attendee_address("  ", @addresses) == nil
    end
  end
end
