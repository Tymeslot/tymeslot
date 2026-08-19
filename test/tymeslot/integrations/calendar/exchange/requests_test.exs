defmodule Tymeslot.Integrations.Calendar.Exchange.RequestsTest do
  use ExUnit.Case, async: true

  import SweetXml, only: [sigil_x: 2]

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Exchange.Requests
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  @from ~U[2026-09-01 00:00:00Z]
  @to ~U[2026-10-01 00:00:00Z]

  describe "find_folder/0" do
    test "asks for calendar folders under the mailbox root with deep traversal" do
      xml = Requests.find_folder()

      assert xml =~ ~s(<m:FindFolder Traversal="Deep">)
      assert xml =~ ~s(<t:DistinguishedFolderId Id="msgfolderroot"/>)
      assert xml =~ ~s(<t:BaseShape>Default</t:BaseShape>)
    end

    test "is well-formed XML the enveloped values read back out of" do
      assert {:ok, doc} = Requests.find_folder() |> Soap.envelope() |> Soap.parse()

      assert Soap.xpath(doc, ~x"//m:FindFolder/@Traversal"s) == "Deep"
      assert Soap.xpath(doc, ~x"//m:FindFolder/m:FolderShape/t:BaseShape/text()"s) == "Default"

      assert Soap.xpath(doc, ~x"//m:ParentFolderIds/t:DistinguishedFolderId/@Id"s) ==
               "msgfolderroot"
    end
  end

  describe "find_item/3" do
    test "builds a CalendarView over the given range for the given folder" do
      xml = Requests.find_item("AAABBB==", @from, @to)

      assert xml =~ ~s(<m:FindItem Traversal="Shallow">)
      assert xml =~ ~s(<t:BaseShape>IdOnly</t:BaseShape>)
      assert xml =~ ~s(StartDate="2026-09-01T00:00:00Z")
      assert xml =~ ~s(EndDate="2026-10-01T00:00:00Z")
      assert xml =~ ~s(<t:FolderId Id="AAABBB=="/>)
    end

    test "renders the range in UTC whatever zone it arrives in" do
      berlin_from = DateTime.shift_zone!(@from, "Europe/Berlin")
      berlin_to = DateTime.shift_zone!(@to, "Europe/Berlin")

      xml = Requests.find_item(:calendar, berlin_from, berlin_to)

      assert xml =~ ~s(StartDate="2026-09-01T00:00:00Z")
      assert xml =~ ~s(EndDate="2026-10-01T00:00:00Z")
    end

    test "drops sub-second precision from the range" do
      xml = Requests.find_item(:calendar, %{@from | microsecond: {123_456, 6}}, @to)

      assert xml =~ ~s(StartDate="2026-09-01T00:00:00Z")
    end

    test "escapes XML metacharacters in the folder id" do
      xml = Requests.find_item(~s(a"b&c<d>e'f), @from, @to)

      assert xml =~ ~s(<t:FolderId Id="a&quot;b&amp;c&lt;d&gt;e&apos;f"/>)
    end

    test "targets the distinguished calendar folder when given :calendar" do
      xml = Requests.find_item(:calendar, @from, @to)

      assert xml =~ ~s(<t:DistinguishedFolderId Id="calendar"/>)
    end

    test "is well-formed XML the enveloped values read back out of" do
      assert {:ok, doc} =
               "AAABBB==" |> Requests.find_item(@from, @to) |> Soap.envelope() |> Soap.parse()

      assert Soap.xpath(doc, ~x"//m:FindItem/@Traversal"s) == "Shallow"
      assert Soap.xpath(doc, ~x"//m:FindItem/m:ItemShape/t:BaseShape/text()"s) == "IdOnly"
      assert Soap.xpath(doc, ~x"//m:CalendarView/@StartDate"s) == "2026-09-01T00:00:00Z"
      assert Soap.xpath(doc, ~x"//m:CalendarView/@EndDate"s) == "2026-10-01T00:00:00Z"
      assert Soap.xpath(doc, ~x"//m:ParentFolderIds/t:FolderId/@Id"s) == "AAABBB=="
    end

    test "escapes the folder id into one the parser reads back unchanged" do
      folder = ~s(a"b&c<d>e'f)

      assert {:ok, doc} =
               folder |> Requests.find_item(@from, @to) |> Soap.envelope() |> Soap.parse()

      assert Soap.xpath(doc, ~x"//m:ParentFolderIds/t:FolderId/@Id"s) == folder
    end

    test "refuses a folder that is neither :calendar nor an id" do
      # Produced at runtime rather than written as `:default`, which the type
      # checker rejects against the guarded head before the guard under test
      # is reached.
      folder = Enum.random([:default])

      assert_raise FunctionClauseError, fn -> Requests.find_item(folder, @from, @to) end
    end
  end

  describe "get_item/1" do
    test "batches every id into one request" do
      xml = Requests.get_item([{"id-1", "ck-1"}, {"id-2", "ck-2"}])

      assert xml =~ ~s(<t:ItemId Id="id-1" ChangeKey="ck-1"/>)
      assert xml =~ ~s(<t:ItemId Id="id-2" ChangeKey="ck-2"/>)
      assert xml =~ ~s(<t:BaseShape>Default</t:BaseShape>)
    end

    test "escapes XML metacharacters in the ids" do
      xml = Requests.get_item([{~s(a&b), ~s(c"d)}])

      assert xml =~ ~s(<t:ItemId Id="a&amp;b" ChangeKey="c&quot;d"/>)
    end

    test "asks for the cancellation flag and the item's time zone on top of the default shape" do
      # Neither is in `BaseShape=Default`, and a server that does not implement
      # them omits them from the response rather than faulting, so asking costs
      # nothing and is the only way to get them where they exist.
      xml = Requests.get_item([{"id-1", "ck-1"}])

      assert xml =~ ~s(<t:FieldURI FieldURI="calendar:IsCancelled"/>)
      assert xml =~ ~s(<t:FieldURI FieldURI="calendar:StartTimeZone"/>)
    end

    test "nests the extra properties inside the item shape where the schema puts them" do
      assert {:ok, doc} =
               [{"id-1", "ck-1"}] |> Requests.get_item() |> Soap.envelope() |> Soap.parse()

      assert Soap.xpath(
               doc,
               ~x"//m:GetItem/m:ItemShape/t:AdditionalProperties/t:FieldURI/@FieldURI"sl
             ) == ["calendar:IsCancelled", "calendar:StartTimeZone"]
    end

    test "does not request MIME content" do
      xml = Requests.get_item([{"id-1", "ck-1"}])

      refute xml =~ "IncludeMimeContent"
    end

    test "refuses to build a request for no items" do
      # Emptied at runtime rather than written as `[]`, which the type checker
      # rejects against the non-empty clause before the runtime guard under
      # test is reached.
      no_ids = Enum.take([{"id-1", "ck-1"}], 0)

      assert_raise FunctionClauseError, fn -> Requests.get_item(no_ids) end
    end

    test "is well-formed XML however many ids the batch joins" do
      for ids <- [[{"id-1", "ck-1"}], [{"id-1", "ck-1"}, {"id-2", "ck-2"}, {"id-3", "ck-3"}]] do
        assert {:ok, doc} = ids |> Requests.get_item() |> Soap.envelope() |> Soap.parse()

        assert Soap.xpath(doc, ~x"//m:ItemIds/t:ItemId/@Id"sl) == Enum.map(ids, &elem(&1, 0))

        assert Soap.xpath(doc, ~x"//m:ItemIds/t:ItemId/@ChangeKey"sl) ==
                 Enum.map(ids, &elem(&1, 1))

        assert Soap.xpath(doc, ~x"//m:GetItem/m:ItemShape/t:BaseShape/text()"s) == "Default"
      end
    end
  end

  describe "get_user_availability/3" do
    test "asks one mailbox for a detailed view over the given window" do
      xml = Requests.get_user_availability("alex@example.com", @from, @to)

      assert xml =~ ~s(<m:GetUserAvailabilityRequest>)
      assert xml =~ ~s(<t:Address>alex@example.com</t:Address>)
      assert xml =~ ~s(<t:AttendeeType>Required</t:AttendeeType>)
      assert xml =~ ~s(<t:RequestedView>Detailed</t:RequestedView>)
    end

    test "renders the window without a zone suffix, since the request names one" do
      # A `FreeBusyViewOptions` bound is an unqualified local time read in the
      # request's `t:TimeZone`. A `Z` on it violates the schema, and a schema
      # violation here is answered with an empty body rather than a fault.
      xml = Requests.get_user_availability("alex@example.com", @from, @to)

      assert xml =~ ~s(<t:StartTime>2026-09-01T00:00:00</t:StartTime>)
      assert xml =~ ~s(<t:EndTime>2026-10-01T00:00:00</t:EndTime>)
      refute xml =~ ~s(00:00:00Z</t:StartTime>)
      refute xml =~ ~s(00:00:00Z</t:EndTime>)
    end

    test "renders the window in UTC whatever zone it arrives in" do
      berlin_from = DateTime.shift_zone!(@from, "Europe/Berlin")
      berlin_to = DateTime.shift_zone!(@to, "Europe/Berlin")

      xml = Requests.get_user_availability("alex@example.com", berlin_from, berlin_to)

      assert xml =~ ~s(<t:StartTime>2026-09-01T00:00:00</t:StartTime>)
      assert xml =~ ~s(<t:EndTime>2026-10-01T00:00:00</t:EndTime>)
    end

    test "drops sub-second precision from the window" do
      xml =
        Requests.get_user_availability(
          "alex@example.com",
          %{@from | microsecond: {123_456, 6}},
          @to
        )

      assert xml =~ ~s(<t:StartTime>2026-09-01T00:00:00</t:StartTime>)
    end

    test "escapes XML metacharacters in the address" do
      xml = Requests.get_user_availability(~s(a"b&c<d>e'f@example.com), @from, @to)

      assert xml =~ ~s(<t:Address>a&quot;b&amp;c&lt;d&gt;e&apos;f@example.com</t:Address>)
    end

    test "sends a complete standard-time rule, since a partial one is answered with nothing" do
      doc = enveloped("alex@example.com")

      assert_time_rule(doc, "StandardTime")
    end

    test "sends a complete daylight-time rule, since a partial one is answered with nothing" do
      doc = enveloped("alex@example.com")

      assert_time_rule(doc, "DaylightTime")
    end

    test "biases the time zone to zero so the window and the answer are both UTC" do
      doc = enveloped("alex@example.com")

      assert Soap.xpath(doc, ~x"//m:GetUserAvailabilityRequest/t:TimeZone/t:Bias/text()"s) == "0"
    end

    test "orders the request's elements as the schema's sequence demands" do
      # xmerl accepts any order; the server does not, and answers a body with
      # no response code rather than a fault when the order is wrong.
      xml = Requests.get_user_availability("alex@example.com", @from, @to)

      assert xml =~
               ~r{<t:TimeZone>\s*<t:Bias>.*</t:Bias>\s*<t:StandardTime>.*</t:StandardTime>\s*<t:DaylightTime>.*</t:DaylightTime>\s*</t:TimeZone>\s*<m:MailboxDataArray>.*</m:MailboxDataArray>\s*<t:FreeBusyViewOptions>}s
    end

    test "orders each time rule's children as the schema's sequence demands" do
      xml = Requests.get_user_availability("alex@example.com", @from, @to)

      assert xml =~
               ~r{<t:StandardTime>\s*<t:Bias>.*</t:Bias>\s*<t:Time>.*</t:Time>\s*<t:DayOrder>.*</t:DayOrder>\s*<t:Month>.*</t:Month>\s*<t:DayOfWeek>.*</t:DayOfWeek>\s*</t:StandardTime>}s
    end

    test "is well-formed XML the enveloped values read back out of" do
      doc = enveloped("alex@example.com")

      assert Soap.xpath(doc, ~x"//m:MailboxDataArray/t:MailboxData/t:Email/t:Address/text()"s) ==
               "alex@example.com"

      assert Soap.xpath(doc, ~x"//t:FreeBusyViewOptions/t:RequestedView/text()"s) == "Detailed"

      assert Soap.xpath(doc, ~x"//t:FreeBusyViewOptions/t:TimeWindow/t:StartTime/text()"s) ==
               "2026-09-01T00:00:00"

      assert Soap.xpath(doc, ~x"//t:FreeBusyViewOptions/t:TimeWindow/t:EndTime/text()"s) ==
               "2026-10-01T00:00:00"
    end

    test "escapes the address into one the parser reads back unchanged" do
      address = ~s(a"b&c<d>e'f@example.com)

      assert Soap.xpath(
               enveloped(address),
               ~x"//m:MailboxDataArray/t:MailboxData/t:Email/t:Address/text()"s
             ) == address
    end

    test "refuses an address that is not a string" do
      # Produced at runtime rather than written as an atom, which the type
      # checker rejects against the guarded head before the guard is reached.
      address = Enum.random([:alex])

      assert_raise FunctionClauseError, fn ->
        Requests.get_user_availability(address, @from, @to)
      end
    end
  end

  defp enveloped(address) do
    {:ok, doc} =
      address
      |> Requests.get_user_availability(@from, @to)
      |> Soap.envelope()
      |> Soap.parse()

    doc
  end

  # Every child is asserted rather than the rule's presence: an incomplete
  # `SerializableTimeZoneTime` is what makes the server answer an empty body
  # with no fault and no response code, which reads as a free calendar.
  defp assert_time_rule(doc, rule) do
    base = "//m:GetUserAvailabilityRequest/t:TimeZone/t:#{rule}"

    assert Soap.xpath(doc, ~x"#{base}/t:Bias/text()"s) == "0"
    assert Soap.xpath(doc, ~x"#{base}/t:Time/text()"s) == "00:00:00"
    assert Soap.xpath(doc, ~x"#{base}/t:DayOrder/text()"s) == "1"
    assert Soap.xpath(doc, ~x"#{base}/t:Month/text()"s) == "1"
    assert Soap.xpath(doc, ~x"#{base}/t:DayOfWeek/text()"s) == "Sunday"
  end
end
