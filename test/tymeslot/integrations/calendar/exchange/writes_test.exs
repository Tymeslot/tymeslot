defmodule Tymeslot.Integrations.Calendar.Exchange.WritesTest do
  @moduledoc """
  Covers the EWS write operations: the bodies `Exchange.Provider`'s write
  callbacks send, and the ones `mix calendar_audit` plants its fixtures with.

  These are the only requests in the codebase that change an Exchange mailbox,
  and no CI job speaks to a server that would notice one going wrong, so the
  bodies themselves are what is pinned. Three properties matter: text is
  escaped before it reaches the XML, since a subject carrying `&` or `<` is
  one of the scenarios the audit deliberately plants; both bound shapes — a
  `Date` pair for all-day, a `DateTime` pair for timed — reach the wire as the
  bounds EWS expects; and a refusal the server states in a 200 body is read as
  a refusal rather than as a write that happened.
  """

  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.Exchange.Writes

  @item_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgHAAEAAAM="
  @change_key "AQAAAKUYe2+83Ooe0DxWVwAAAAAAIQ=="

  # `CreateItem` answers the id and change key inside the item it made.
  defp create_response(id \\ @item_id) do
    response_envelope("CreateItem", """
    <m:Items>
      <t:CalendarItem>
        <t:ItemId Id="#{id}" ChangeKey="#{@change_key}"/>
      </t:CalendarItem>
    </m:Items>
    """)
  end

  # Captures the request body so a test can assert on what was sent, and
  # answers `response`.
  defp capture_body(response) do
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

  defp timed_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        summary: "[Calendar Audit] Timed",
        start_time: ~U[2026-10-06 10:00:00Z],
        end_time: ~U[2026-10-06 11:00:00Z]
      },
      overrides
    )
  end

  describe "create_item/2" do
    test "returns the item id the server assigned" do
      capture_body(create_response())

      assert {:ok, @item_id} = Writes.create_item(config(), timed_fixture())
    end

    test "sends a timed event's bounds as UTC instants" do
      capture_body(create_response())

      assert {:ok, _id} = Writes.create_item(config(), timed_fixture())

      body = sent_body()
      assert body =~ "<t:Start>2026-10-06T10:00:00Z</t:Start>"
      assert body =~ "<t:End>2026-10-06T11:00:00Z</t:End>"
      assert body =~ "<t:IsAllDayEvent>false</t:IsAllDayEvent>"
    end

    test "shifts a zoned bound into UTC rather than sending its own offset" do
      capture_body(create_response())

      # A `CalendarView` bound is an absolute instant, and a scenario is free to
      # express one in any zone. 12:00 in Berlin on this date is 10:00 UTC.
      from = DateTime.new!(~D[2026-10-06], ~T[12:00:00], "Europe/Berlin")
      to = DateTime.new!(~D[2026-10-06], ~T[13:00:00], "Europe/Berlin")

      assert {:ok, _id} =
               Writes.create_item(config(), timed_fixture(%{start_time: from, end_time: to}))

      assert sent_body() =~ "<t:Start>2026-10-06T10:00:00Z</t:Start>"
    end

    test "sends an all-day event with an exclusive end, one day past the last" do
      capture_body(create_response())

      # The audit spells a single-day all-day event as start == end, matching
      # what every other provider's create path is handed. EWS wants the next
      # midnight, so a body echoing the caller's date would make the event
      # zero-length and the server would reject or silently widen it.
      assert {:ok, _id} =
               Writes.create_item(
                 config(),
                 timed_fixture(%{start_time: ~D[2026-10-06], end_time: ~D[2026-10-06]})
               )

      body = sent_body()
      assert body =~ "<t:Start>2026-10-06T00:00:00Z</t:Start>"
      assert body =~ "<t:End>2026-10-07T00:00:00Z</t:End>"
      assert body =~ "<t:IsAllDayEvent>true</t:IsAllDayEvent>"
    end

    test "escapes the five XML metacharacters in a fixture's own text" do
      capture_body(create_response())

      assert {:ok, _id} =
               Writes.create_item(
                 config(),
                 timed_fixture(%{
                   summary: ~s(Chars & "Quotes" <b> 'x'),
                   location: "A & B",
                   description: "<not-an-element>"
                 })
               )

      body = sent_body()

      # The raw metacharacters must not survive into the body: an unescaped `<`
      # in a subject makes the whole request malformed XML, which a server
      # answers with a schema fault rather than a usable error.
      assert body =~
               "<t:Subject>Chars &amp; &quot;Quotes&quot; &lt;b&gt; &apos;x&apos;</t:Subject>"

      assert body =~ "<t:Location>A &amp; B</t:Location>"
      assert body =~ "&lt;not-an-element&gt;"
      refute body =~ "<b>"
    end

    test "maps a transparent fixture onto the one free/busy status that frees time" do
      capture_body(create_response())

      assert {:ok, _id} =
               Writes.create_item(config(), timed_fixture(%{transparency: :transparent}))

      assert sent_body() =~ "<t:LegacyFreeBusyStatus>Free</t:LegacyFreeBusyStatus>"
    end

    test "defaults to busy when the fixture says nothing about transparency" do
      capture_body(create_response())

      assert {:ok, _id} = Writes.create_item(config(), timed_fixture())

      assert sent_body() =~ "<t:LegacyFreeBusyStatus>Busy</t:LegacyFreeBusyStatus>"
    end

    test "omits an element for an absent optional field rather than sending it empty" do
      capture_body(create_response())

      assert {:ok, _id} = Writes.create_item(config(), timed_fixture())

      body = sent_body()
      refute body =~ "<t:Location>"
      refute body =~ "<t:Body"
      refute body =~ "<t:Recurrence>"
    end

    test "sends a daily count recurrence as an EWS pattern and range" do
      capture_body(create_response())

      assert {:ok, _id} =
               Writes.create_item(
                 config(),
                 timed_fixture(%{recurrence: %{freq: :daily, interval: 1, count: 3}})
               )

      body = sent_body()
      assert body =~ "<t:DailyRecurrence><t:Interval>1</t:Interval></t:DailyRecurrence>"
      assert body =~ "<t:StartDate>2026-10-06</t:StartDate>"
      assert body =~ "<t:NumberOfOccurrences>3</t:NumberOfOccurrences>"
    end

    test "suppresses meeting invitations" do
      capture_body(create_response())

      assert {:ok, _id} = Writes.create_item(config(), timed_fixture())

      # An audit run must never mail anybody. A server that decided to invite
      # on its own would do so silently, so the instruction is asserted here
      # rather than trusted to a comment.
      assert sent_body() =~ ~s(SendMeetingInvitations="SendToNone")
    end

    test "reports a server refusal rather than a usable id" do
      respond_with(
        200,
        soap_envelope("""
        <m:CreateItemResponse>
          <m:ResponseMessages>
            <m:CreateItemResponseMessage ResponseClass="Error">
              <m:ResponseCode>ErrorAccessDenied</m:ResponseCode>
            </m:CreateItemResponseMessage>
          </m:ResponseMessages>
        </m:CreateItemResponse>
        """)
      )

      assert {:error, {:response_code, "ErrorAccessDenied"}} =
               Writes.create_item(config(), timed_fixture())
    end

    test "refuses a success carrying no item id" do
      # Nothing could address the fixture afterwards, so it would be planted in
      # the mailbox and never removed. Failing here says so; `{:ok, nil}` would
      # surface as a confusing delete failure a scenario later.
      respond_with(200, response_envelope("CreateItem"))

      assert {:error, :no_item_id} = Writes.create_item(config(), timed_fixture())
    end
  end

  describe "delete_item/2" do
    test "hard-deletes the item by id" do
      capture_body(response_envelope("DeleteItem"))

      assert :ok = Writes.delete_item(config(), @item_id)

      body = sent_body()
      assert body =~ ~s(<t:ItemId Id="#{@item_id}"/>)
      # A fixture moved to Deleted Items is still in the mailbox, and the next
      # run reading the whole mailbox would find every earlier run's leftovers.
      assert body =~ ~s(DeleteType="HardDelete")
      assert body =~ ~s(SendMeetingCancellations="SendToNone")
    end

    test "surfaces a refusal instead of reporting a removal that did not happen" do
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

      # `ErrorItemNotFound` collapses to `:not_found` rather than travelling as
      # the server's own code: it is the one refusal a caller acts on, and
      # `Meetings.CalendarEventSync` reads it as "already deleted".
      assert {:error, :not_found} = Writes.delete_item(config(), @item_id)
    end
  end
end
