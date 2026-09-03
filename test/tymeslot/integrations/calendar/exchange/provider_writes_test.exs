defmodule Tymeslot.Integrations.Calendar.Exchange.ProviderWritesTest do
  @moduledoc """
  Covers the provider's three write callbacks: the shapes they send, the shape
  they answer, and the one refusal a caller acts on.

  Split from `Exchange.ProviderTest` rather than living beside the reads,
  because the two ask different questions of the same module: the reads are
  about never reporting a busy mailbox as free, and these are about a booking
  reaching the mailbox and staying addressable afterwards.

  `Exchange.WritesTest` pins the request bodies in detail. What is pinned here
  is the callback contract the rest of the system depends on — chiefly that a
  create answers `%{id: item_id}`, since `Meetings.CalendarEventSync` reads a
  bare binary as a uid and files it in the wrong column.
  """

  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Security.Encryption

  describe "write callbacks" do
    @created_item_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgHAAEAAAM="

    test "create_event/2 answers the item id under an :id key, which is what gets persisted" do
      respond_with(200, create_response())

      # `%{id: _}` and not a bare binary: `CalendarEventSync.put_provider_mapping/2`
      # reads a binary as a *uid* and files it in the wrong column, so the next
      # update would address the item by something EWS never issued.
      assert {:ok, %{id: @created_item_id}} = Provider.create_event(config(), event_data())
    end

    test "create_event/2 writes to the folder the integration nominates" do
      folder = "AAAAAHWP+wXiGGhNkiDQ+d65ZYgBAAEAAAA="
      capture_body(create_response())

      client =
        Provider.build_booking_client_config(integration(%{default_booking_calendar_id: folder}))

      assert {:ok, _created} = Provider.create_event(client, event_data())

      body = sent_body()
      assert body =~ ~s(<t:FolderId Id="#{folder}"/>)
      refute body =~ ~s(<t:DistinguishedFolderId Id="calendar"/>)
    end

    test "create_event/2 sends no attendees, so the server invites nobody" do
      capture_body(create_response())

      assert {:ok, _created} = Provider.create_event(config(), event_data())

      body = sent_body()
      # Tymeslot has already emailed both parties. An item carrying attendees
      # would be a meeting rather than an appointment, and Exchange would send
      # its own invitation on top of the one already sent.
      assert body =~ ~s(SendMeetingInvitations="SendToNone")
      refute body =~ "RequiredAttendees"
      refute body =~ "OptionalAttendees"

      # The address still reaches the organiser's diary, in the description
      # the builder assembles. That is the whole point of dropping the
      # attendee fields rather than the information.
      assert body =~ "attendee@example.com"
      assert body =~ "<t:Body BodyType=\"Text\">"
    end

    test "update_event/3 addresses the item by id, with no change key" do
      capture_body(response_envelope("UpdateItem"))

      assert :ok = Provider.update_event(config(), @created_item_id, event_data())

      body = sent_body()
      assert body =~ "<m:UpdateItem"
      assert body =~ ~s(<t:ItemId Id="#{@created_item_id}"/>)
      # Sending one would cost a `GetItem` before every write to keep it fresh,
      # and buy a conflict check this caller cannot act on.
      refute body =~ "ChangeKey"
    end

    test "update_event/3 clears a field the meeting no longer carries" do
      capture_body(response_envelope("UpdateItem"))

      assert :ok =
               Provider.update_event(
                 config(),
                 @created_item_id,
                 event_data(%{location: nil})
               )

      # Omitting the field instead would leave the old room showing on a
      # rescheduled booking, and an empty `t:SetItemField` is a schema
      # violation, so a delete is the only way to say it.
      assert sent_body() =~
               ~s(<t:DeleteItemField><t:FieldURI FieldURI="calendar:Location"/></t:DeleteItemField>)
    end

    test "delete_event/3 reports a vanished item as :not_found, which is the recreate signal" do
      respond_with(
        200,
        soap_envelope("""
        <m:DeleteItemResponse>
          <m:ResponseMessages>
            <m:DeleteItemResponseMessage ResponseClass="Error">
              <m:ResponseCode>ErrorItemNotFound</m:ResponseCode>
            </m:DeleteItemResponseMessage>
          </m:ResponseMessages>
        </m:DeleteItemResponse>
        """)
      )

      assert {:error, :not_found} = Provider.delete_event(config(), @created_item_id, [])
    end

    test "build_booking_client_config/1 always resolves, falling back to the default calendar" do
      # Unlike the CalDAV family's, which answers nil when no path resolves. A
      # mailbox always has a default calendar, so there is no configuration in
      # which an Exchange integration exists but cannot receive a booking.
      assert %{booking_folder_id: :calendar} = Provider.build_booking_client_config(integration())
    end

    test "build_booking_client_config/1 carries the integration the mapping is persisted against" do
      assert %{calendar_integration_id: 4242} =
               Provider.build_booking_client_config(integration(%{id: 4242}))
    end
  end

  # --- Helpers ---

  # The canonical map `CalendarEventBuilder.build_event_data/1` produces, cut
  # to the keys this provider reads.
  defp event_data(overrides \\ %{}) do
    Map.merge(
      %{
        uid: "tymeslot-uid-that-ews-will-ignore",
        summary: "Intro call",
        description: "With Attendee Name (attendee@example.com)",
        start_time: ~U[2026-10-05 09:00:00Z],
        end_time: ~U[2026-10-05 09:30:00Z],
        location: "https://meet.example.com/abc",
        transparency: :opaque,
        attendee_email: "attendee@example.com",
        reminders: [%{method: :popup, minutes_before: 15}]
      },
      overrides
    )
  end

  defp create_response do
    response_envelope("CreateItem", """
    <m:Items>
      <t:CalendarItem><t:ItemId Id="#{@created_item_id}" ChangeKey="CK=="/></t:CalendarItem>
    </m:Items>
    """)
  end

  defp capture_body(response) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      send(test_pid, {:request_body, body})
      respond(conn, response)
    end)
  end

  defp sent_body do
    assert_received {:request_body, body}
    body
  end

  defp respond(conn, body) do
    conn
    |> Conn.put_resp_content_type("text/xml")
    |> Conn.resp(200, body)
  end

  defp integration(overrides \\ %{}) do
    Map.merge(
      %CalendarIntegrationSchema{
        id: 1,
        provider: "exchange",
        base_url: "https://mail.example.com/EWS/Exchange.asmx",
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        verify_ssl: true,
        calendar_list: []
      },
      Map.new(overrides)
    )
  end
end
