defmodule Tymeslot.Integrations.Calendar.Exchange.FolderDiscoveryTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Exchange.FolderDiscovery
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  describe "parse_calendars/1" do
    test "returns one entry per calendar folder" do
      folders = calendar_folder("cal-1", "Calendar") <> calendar_folder("cal-2", "Team")

      assert {:ok, [first, second]} = FolderDiscovery.parse_calendars(response(folders))

      assert %CalendarEntry{} = first
      assert first.id == "cal-1"
      assert first.name == "Calendar"
      assert first.type == "calendar"
      assert first.selected == false
      assert first.read_only == false
      assert second.id == "cal-2"
      assert second.name == "Team"
      assert second.type == "calendar"
    end

    test "ignores every folder that is not a calendar" do
      folders =
        """
        <t:Folder>
          <t:FolderId Id="inbox" ChangeKey="ck-inbox"/>
          <t:DisplayName>Inbox</t:DisplayName>
        </t:Folder>
        <t:ContactsFolder>
          <t:FolderId Id="contacts" ChangeKey="ck-contacts"/>
          <t:DisplayName>Contacts</t:DisplayName>
        </t:ContactsFolder>
        <t:TasksFolder>
          <t:FolderId Id="tasks" ChangeKey="ck-tasks"/>
          <t:DisplayName>Tasks</t:DisplayName>
        </t:TasksFolder>
        """ <> calendar_folder("cal-1", "Calendar")

      assert {:ok, [only]} = FolderDiscovery.parse_calendars(response(folders))
      assert only.id == "cal-1"
    end

    test "marks the folder named Calendar as primary, wherever it appears" do
      folders = calendar_folder("cal-2", "Team") <> calendar_folder("cal-1", "Calendar")

      assert {:ok, entries} = FolderDiscovery.parse_calendars(response(folders))

      assert Enum.map(entries, &{&1.id, &1.primary}) == [{"cal-2", false}, {"cal-1", true}]
    end

    test "marks at most one folder primary when the name repeats" do
      folders =
        calendar_folder("cal-1", "Calendar") <>
          calendar_folder("cal-2", "Calendar") <> calendar_folder("cal-3", "Team")

      assert {:ok, entries} = FolderDiscovery.parse_calendars(response(folders))

      assert Enum.map(entries, &{&1.id, &1.primary}) ==
               [{"cal-1", true}, {"cal-2", false}, {"cal-3", false}]
    end

    test "marks the sole calendar of a mailbox primary whatever it is named" do
      # The default calendar cannot be deleted, so a mailbox holding one
      # calendar folder holds its default one, whichever language named it.
      assert {:ok, [only]} =
               FolderDiscovery.parse_calendars(response(calendar_folder("cal-de", "Kalender")))

      assert only.id == "cal-de"
      assert only.primary == true
    end

    test "leaves a localised mailbox with several calendars without a primary" do
      folders = calendar_folder("cal-de", "Kalender") <> calendar_folder("cal-team", "Team")

      assert {:ok, entries} = FolderDiscovery.parse_calendars(response(folders))

      assert Enum.map(entries, &{&1.id, &1.primary}) ==
               [{"cal-de", false}, {"cal-team", false}]
    end

    test "keeps a calendar whose display name the server omitted" do
      folder = """
      <t:CalendarFolder>
        <t:FolderId Id="cal-nameless" ChangeKey="ck-nameless"/>
      </t:CalendarFolder>
      """

      assert {:ok, [only]} = FolderDiscovery.parse_calendars(response(folder))

      assert only.id == "cal-nameless"
      assert only.name == nil
    end

    test "drops a folder carrying no folder id, since nothing could sync it" do
      folder = """
      <t:CalendarFolder>
        <t:DisplayName>Ghost</t:DisplayName>
      </t:CalendarFolder>
      """

      assert {:ok, entries} =
               FolderDiscovery.parse_calendars(
                 response(folder <> calendar_folder("cal-1", "Team"))
               )

      assert Enum.map(entries, & &1.id) == ["cal-1"]
    end

    test "returns an empty list when the mailbox has no calendar folders" do
      assert {:ok, []} = FolderDiscovery.parse_calendars(response(""))
    end

    test "surfaces a failed response message rather than reporting no calendars" do
      # `{:ok, []}` here would be read as "this mailbox has no calendars" and
      # persisted as an emptied calendar list.
      message = """
      <m:FindFolderResponseMessage ResponseClass="Error">
        <m:MessageText>Access is denied.</m:MessageText>
        <m:ResponseCode>ErrorAccessDenied</m:ResponseCode>
      </m:FindFolderResponseMessage>
      """

      assert FolderDiscovery.parse_calendars(document(message)) ==
               {:error, {:response_code, "ErrorAccessDenied"}}
    end

    test "surfaces a failed response message even when another one succeeded" do
      failed = """
      <m:FindFolderResponseMessage ResponseClass="Error">
        <m:ResponseCode>ErrorNonExistentMailbox</m:ResponseCode>
      </m:FindFolderResponseMessage>
      """

      document = document(success_message(calendar_folder("cal-1", "Calendar")) <> failed)

      assert FolderDiscovery.parse_calendars(document) ==
               {:error, {:response_code, "ErrorNonExistentMailbox"}}
    end

    test "reports a response carrying no response message at all" do
      assert FolderDiscovery.parse_calendars(document("")) == {:error, :no_response_messages}
    end

    test "resolves the EWS elements by namespace rather than by prefix" do
      # The prefixes are ones no xpath in this codebase spells, so every value
      # below can only have been extracted by namespace URI. An unbound prefix
      # yields `""` rather than an error, which is how a namespace regression
      # reaches production looking like an empty calendar list.
      document =
        renamed_prefix_document("""
        <msgs:FindFolderResponseMessage ResponseClass="Success">
          <msgs:ResponseCode>NoError</msgs:ResponseCode>
          <msgs:RootFolder TotalItemsInView="2" IncludesLastItemInRange="true">
            <types:Folders>
              <types:Folder>
                <types:FolderId Id="inbox" ChangeKey="ck-inbox"/>
                <types:DisplayName>Inbox</types:DisplayName>
              </types:Folder>
              <types:CalendarFolder>
                <types:FolderId Id="cal-9" ChangeKey="ck-9"/>
                <types:DisplayName>Calendar</types:DisplayName>
              </types:CalendarFolder>
              <types:CalendarFolder>
                <types:FolderId Id="cal-10" ChangeKey="ck-10"/>
                <types:DisplayName>Team</types:DisplayName>
              </types:CalendarFolder>
            </types:Folders>
          </msgs:RootFolder>
        </msgs:FindFolderResponseMessage>
        """)

      assert {:ok, [first, second]} = FolderDiscovery.parse_calendars(document)

      assert first.id == "cal-9"
      assert first.name == "Calendar"
      assert first.primary == true
      assert second.id == "cal-10"
      assert second.name == "Team"
      assert second.primary == false
    end
  end

  defp calendar_folder(id, name) do
    """
    <t:CalendarFolder>
      <t:FolderId Id="#{id}" ChangeKey="ck-#{id}"/>
      <t:DisplayName>#{name}</t:DisplayName>
      <t:TotalCount>3</t:TotalCount>
      <t:ChildFolderCount>0</t:ChildFolderCount>
    </t:CalendarFolder>
    """
  end

  defp success_message(folders) do
    """
    <m:FindFolderResponseMessage ResponseClass="Success">
      <m:ResponseCode>NoError</m:ResponseCode>
      <m:RootFolder TotalItemsInView="1" IncludesLastItemInRange="true">
        <t:Folders>#{folders}</t:Folders>
      </m:RootFolder>
    </m:FindFolderResponseMessage>
    """
  end

  defp response(folders), do: folders |> success_message() |> document()

  defp document(response_messages) do
    {:ok, doc} =
      Soap.parse("""
      <?xml version="1.0"?>
      <SOAP:Envelope xmlns:SOAP="http://schemas.xmlsoap.org/soap/envelope/">
        <SOAP:Body>
          <m:FindFolderResponse xmlns:m="http://schemas.microsoft.com/exchange/services/2006/messages"
                                xmlns:t="http://schemas.microsoft.com/exchange/services/2006/types">
            <m:ResponseMessages>#{response_messages}</m:ResponseMessages>
          </m:FindFolderResponse>
        </SOAP:Body>
      </SOAP:Envelope>
      """)

    doc
  end

  defp renamed_prefix_document(response_messages) do
    {:ok, doc} =
      Soap.parse("""
      <?xml version="1.0"?>
      <env:Envelope xmlns:env="http://schemas.xmlsoap.org/soap/envelope/">
        <env:Body>
          <msgs:FindFolderResponse
              xmlns:msgs="http://schemas.microsoft.com/exchange/services/2006/messages"
              xmlns:types="http://schemas.microsoft.com/exchange/services/2006/types">
            <msgs:ResponseMessages>#{response_messages}</msgs:ResponseMessages>
          </msgs:FindFolderResponse>
        </env:Body>
      </env:Envelope>
      """)

    doc
  end
end
