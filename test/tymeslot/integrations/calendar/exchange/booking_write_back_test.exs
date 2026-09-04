defmodule Tymeslot.Integrations.Calendar.Exchange.BookingWriteBackTest do
  @moduledoc """
  The journey the write path exists for: a meeting booked against an Exchange
  mailbox reaches that mailbox, and can then be rescheduled and cancelled
  there.

  Everything between the meeting and the SOAP body is real — the booking client
  resolution, the provider adapter, the event builder, the request builders —
  and only the HTTP boundary is stubbed. The unit tests beside this one pin the
  bodies; what this pins is that a booking actually travels the whole way, and
  that the item id the server assigns comes back and is persisted, since
  without that every later update addresses an item Exchange never issued.
  """

  use Tymeslot.DataCase, async: false

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :integration

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.ExchangeCase
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  @base_url "https://mail.example.com/EWS/Exchange.asmx"
  @folder_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgBAAEAAAA="
  @item_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgHAAEAAAM="

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    # The suite points `:calendar_module` at a Mox double, which is right for
    # every test that only cares that a sync was *asked for*. This one is about
    # what actually reaches the mailbox, so the real implementation runs and
    # the HTTP boundary is the only thing stubbed.
    #
    # `Calendar.Operations` and not `Calendar.Events`: both read this same key,
    # so pointing it at the `Events` facade makes it delegate to itself and
    # spin. `Operations` is what `Events` resolves to when the key is unset,
    # which is the production arrangement.
    with_config(:tymeslot, :calendar_module, Tymeslot.Integrations.Calendar.Operations)
    ExchangeCase.reset_breaker(@base_url)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "exchange",
        base_url: @base_url,
        username_encrypted: Encryption.encrypt("user@example.com"),
        password_encrypted: Encryption.encrypt("secret"),
        provider_account_email: "user@example.com",
        default_booking_calendar_id: @folder_id,
        calendar_list: [
          %CalendarEntry{id: @folder_id, name: "Calendar", selected: true, read_only: false}
        ]
      )

    insert(:profile, user: user, primary_calendar_integration_id: integration.id)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        title: "Intro call",
        start_time: ~U[2026-10-05 09:00:00Z],
        end_time: ~U[2026-10-05 09:30:00Z]
      )

    %{user: user, integration: integration, meeting: meeting}
  end

  test "a booking is written to the mailbox and its item id persisted", %{
    integration: integration,
    meeting: meeting
  } do
    capture_bodies(create_response())

    assert :ok = CalendarEventSync.create(meeting.id, 1)

    body = sent_body()
    assert body =~ "<m:CreateItem"
    assert body =~ "<t:Subject>Intro call</t:Subject>"
    assert body =~ "<t:Start>2026-10-05T09:00:00Z</t:Start>"
    # The nominated folder, not the mailbox default: a booking landing in the
    # wrong folder is one the organiser's grid may never show.
    assert body =~ ~s(<t:FolderId Id="#{@folder_id}"/>)

    {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)

    # The whole reason `create_event/2` answers `%{id: _}`. Persisted as a uid
    # instead, every later update would address an item EWS never issued.
    assert reloaded.provider_event_id == @item_id
    assert reloaded.calendar_integration_id == integration.id
  end

  test "a reschedule updates the item the create returned", %{meeting: meeting} do
    capture_bodies(create_response())
    assert :ok = CalendarEventSync.create(meeting.id, 1)
    sent_body()

    {:ok, created} = MeetingQueries.get_meeting(meeting.id)

    {:ok, moved} =
      created
      |> Changeset.change(%{
        start_time: ~U[2026-10-06 14:00:00Z],
        end_time: ~U[2026-10-06 14:30:00Z]
      })
      |> Repo.update()

    capture_bodies(ExchangeCase.response_envelope("UpdateItem", ""))

    assert :ok = CalendarEventSync.update(moved.id, 1)

    body = sent_body()
    assert body =~ "<m:UpdateItem"
    assert body =~ ~s(<t:ItemId Id="#{@item_id}"/>)
    assert body =~ "<t:Start>2026-10-06T14:00:00Z</t:Start>"
  end

  test "a cancellation removes the item, and a vanished one is not an error", %{meeting: meeting} do
    capture_bodies(create_response())
    assert :ok = CalendarEventSync.create(meeting.id, 1)
    sent_body()

    # The deletion only runs once the meeting no longer expects an event, which
    # is what cancelling it establishes.
    {:ok, cancelled} = MeetingQueries.get_meeting(meeting.id)

    cancelled
    |> Changeset.change(%{status: "cancelled", cancelled_at: DateTime.utc_now(:second)})
    |> Repo.update!()

    capture_bodies(
      ExchangeCase.soap_envelope("""
      <m:DeleteItemResponse>
        <m:ResponseMessages>
          <m:DeleteItemResponseMessage ResponseClass="Error">
            <m:ResponseCode>ErrorItemNotFound</m:ResponseCode>
          </m:DeleteItemResponseMessage>
        </m:ResponseMessages>
      </m:DeleteItemResponse>
      """)
    )

    # Someone deleted the meeting in Outlook first. Cancelling in Tymeslot must
    # still succeed: the desired end state is already the actual one.
    assert :ok = CalendarEventSync.delete(meeting.id, 1)

    assert sent_body() =~ "<m:DeleteItem"
  end

  # --- Helpers ---

  defp create_response do
    ExchangeCase.response_envelope("CreateItem", """
    <m:Items>
      <t:CalendarItem><t:ItemId Id="#{@item_id}" ChangeKey="CK=="/></t:CalendarItem>
    </m:Items>
    """)
  end

  defp capture_bodies(response) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      send(test_pid, {:request_body, body})

      conn
      |> Conn.put_resp_content_type("text/xml")
      |> Conn.resp(200, response)
    end)
  end

  defp sent_body do
    assert_received {:request_body, body}
    body
  end
end
