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
end
