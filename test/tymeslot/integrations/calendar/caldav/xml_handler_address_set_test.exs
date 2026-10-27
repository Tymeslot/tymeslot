defmodule Tymeslot.Integrations.Calendar.CalDAV.XmlHandlerAddressSetTest do
  @moduledoc """
  Reading the addresses a CalDAV server counts as an account's own, which
  decides how a booking on Open-Xchange lists its organiser (issue #151).
  """
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalDAV.XmlHandler

  describe "parse_calendar_user_address_set/1" do
    # mailbox.org's own answer, its principal hrefs beside the addresses.
    @mailbox_org_address_set """
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/principals/users/3</D:href>
        <D:propstat>
          <D:prop>
            <calendar-user-address-set xmlns="urn:ietf:params:xml:ns:caldav">
              <D:href>mailto:alias@mailbox.org</D:href>
              <D:href preferred="1">mailto:Login@Mailbox.org</D:href>
              <D:href>/principals/users/3</D:href>
              <D:href>urn:uuid:00889475-0000-0003-00fc-c0e11e000001</D:href>
            </calendar-user-address-set>
          </D:prop>
          <D:status>HTTP/1.1 200 OK</D:status>
        </D:propstat>
      </D:response>
    </D:multistatus>
    """

    test "answers the mailto addresses in lower case, the preferred one first" do
      assert XmlHandler.parse_calendar_user_address_set(@mailbox_org_address_set) ==
               {:ok, ["login@mailbox.org", "alias@mailbox.org"]}
    end

    test "keeps the server's order when it prefers none" do
      xml = String.replace(@mailbox_org_address_set, ~s( preferred="1"), "")

      assert XmlHandler.parse_calendar_user_address_set(xml) ==
               {:ok, ["alias@mailbox.org", "login@mailbox.org"]}
    end

    test "is not found when the set holds no address" do
      xml = String.replace(@mailbox_org_address_set, ~r/<D:href[^>]*>mailto:[^<]*<\/D:href>/, "")

      assert XmlHandler.parse_calendar_user_address_set(xml) == {:error, :not_found}
    end

    test "returns an error on malformed XML" do
      assert {:error, _reason} = XmlHandler.parse_calendar_user_address_set("<<< not xml")
    end
  end
end
