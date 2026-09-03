defmodule Tymeslot.Integrations.Calendar.Exchange.ItemSyncTest do
  @moduledoc """
  Covers the `SyncFolderItems` change feed: what a response means, and how the
  drain loop behaves when one response is not the whole story.

  The properties worth pinning are the ones where a wrong reading is silent. A
  failed response message carries no `m:Changes`, so a reader that walks
  straight to them answers "nothing changed" for a folder it could not read,
  and the incremental caller then leaves the cache untouched forever. A
  response stating `IncludesLastItemInRange=false` has more behind it, so a
  reader that stops there stores a token claiming it saw changes it never
  fetched.
  """

  use Tymeslot.ExchangeCase, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.Exchange.ItemSync
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  @first_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgHAAEAAAM="
  @second_id "AAAAAHWP+wXiGGhNkiDQ+d65ZYgHAAEAAAQ="
  @token "AgACARdADwAAAAEABQAAAAkAUgACAThQAAIBlmcQ"

  describe "parse_changes/1" do
    test "separates creates, updates and deletes, and carries the token" do
      doc =
        parse(
          changes_envelope(
            """
            <t:Create><t:CalendarItem><t:ItemId Id="#{@first_id}" ChangeKey="CK1"/></t:CalendarItem></t:Create>
            <t:Update><t:CalendarItem><t:ItemId Id="#{@second_id}" ChangeKey="CK2"/></t:CalendarItem></t:Update>
            <t:Delete><t:ItemId Id="gone-id"/></t:Delete>
            """,
            @token
          )
        )

      assert {:ok, changes} = ItemSync.parse_changes(doc)

      assert changes.created == [{@first_id, "CK1"}]
      assert changes.updated == [{@second_id, "CK2"}]
      assert changes.deleted == ["gone-id"]
      assert changes.sync_state == @token
      assert changes.last?
    end

    test "reads a stated failure as an error, not as a folder where nothing happened" do
      doc =
        parse(
          soap_envelope("""
          <m:SyncFolderItemsResponse>
            <m:ResponseMessages>
              <m:SyncFolderItemsResponseMessage ResponseClass="Error">
                <m:ResponseCode>ErrorAccessDenied</m:ResponseCode>
              </m:SyncFolderItemsResponseMessage>
            </m:ResponseMessages>
          </m:SyncFolderItemsResponse>
          """)
        )

      # The whole risk of the incremental path: a folder that cannot be read
      # answering as one with no changes leaves its cached rows frozen, and
      # nothing downstream can tell the two apart.
      assert {:error, {:response_code, "ErrorAccessDenied"}} = ItemSync.parse_changes(doc)
    end

    test "reads an empty change set as genuinely empty" do
      assert {:ok, changes} = ItemSync.parse_changes(parse(changes_envelope("", @token)))

      assert changes.created == []
      assert changes.updated == []
      assert changes.deleted == []
      assert changes.sync_state == @token
    end

    test "ignores items in a calendar folder that are not calendar items" do
      doc =
        parse(
          changes_envelope(
            """
            <t:Create><t:MeetingRequest><t:ItemId Id="mr-1"/></t:MeetingRequest></t:Create>
            <t:Create><t:CalendarItem><t:ItemId Id="#{@first_id}"/></t:CalendarItem></t:Create>
            """,
            @token
          )
        )

      # A meeting request is not something the grid can render, and fetching it
      # as though it were would put an unusable row through the normaliser.
      assert {:ok, %{created: [{@first_id, ""}]}} = ItemSync.parse_changes(doc)
    end
  end

  describe "fetch_changes/3" do
    test "sends no SyncState on the first call, and the stored one afterwards" do
      capture_bodies(changes_envelope("", @token))

      assert {:ok, _changes} = ItemSync.fetch_changes(config(), :calendar, nil)
      refute sent_body() =~ "<m:SyncState>"

      capture_bodies(changes_envelope("", @token))

      assert {:ok, _changes} = ItemSync.fetch_changes(config(), :calendar, "stored-token")
      assert sent_body() =~ "<m:SyncState>stored-token</m:SyncState>"
    end

    test "drains every page and answers under the final token" do
      # A caller that stopped at the first page would store `page-1-token`
      # while having seen only half the changes, and the second half would
      # never be reported again.
      respond_in_sequence([
        changes_envelope(
          ~s(<t:Create><t:CalendarItem><t:ItemId Id="#{@first_id}"/></t:CalendarItem></t:Create>),
          "page-1-token",
          "false"
        ),
        changes_envelope(
          ~s(<t:Delete><t:ItemId Id="#{@second_id}"/></t:Delete>),
          "page-2-token",
          "true"
        )
      ])

      assert {:ok, changes} = ItemSync.fetch_changes(config(), :calendar, nil)

      assert changes.created == [{@first_id, ""}]
      assert changes.deleted == [@second_id]
      assert changes.sync_state == "page-2-token"
    end

    test "sends the previous page's token when asking for the next" do
      respond_in_sequence(
        [
          changes_envelope("", "page-1-token", "false"),
          changes_envelope("", "page-2-token", "true")
        ],
        capture: true
      )

      assert {:ok, _changes} = ItemSync.fetch_changes(config(), :calendar, nil)

      assert [first, second] = sent_bodies(2)
      refute first =~ "<m:SyncState>"
      assert second =~ "<m:SyncState>page-1-token</m:SyncState>"
    end

    test "stops rather than looping when a page states more to come but no new token" do
      # Sending nil again would restart the feed and replay the same page
      # forever inside one Oban job.
      respond_with(200, changes_envelope("", nil, "false"))

      assert {:ok, changes} = ItemSync.fetch_changes(config(), :calendar, nil)
      assert changes.sync_state == nil
    end

    test "fails the whole read when a later page fails" do
      respond_in_sequence([
        changes_envelope("", "page-1-token", "false"),
        soap_envelope("""
        <m:SyncFolderItemsResponse>
          <m:ResponseMessages>
            <m:SyncFolderItemsResponseMessage ResponseClass="Error">
              <m:ResponseCode>ErrorInvalidSyncStateData</m:ResponseCode>
            </m:SyncFolderItemsResponseMessage>
          </m:ResponseMessages>
        </m:SyncFolderItemsResponse>
        """)
      ])

      # Answering the first page's changes under its token would acknowledge a
      # span the caller never finished reading.
      assert {:error, {:response_code, "ErrorInvalidSyncStateData"}} =
               ItemSync.fetch_changes(config(), :calendar, nil)
    end
  end

  # --- Helpers ---

  defp parse(xml) do
    assert {:ok, doc} = Soap.parse(xml)
    doc
  end

  defp changes_envelope(changes, token, last \\ "true") do
    soap_envelope("""
    <m:SyncFolderItemsResponse>
      <m:ResponseMessages>
        <m:SyncFolderItemsResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
          #{if token, do: "<m:SyncState>#{token}</m:SyncState>", else: ""}
          <m:IncludesLastItemInRange>#{last}</m:IncludesLastItemInRange>
          <m:Changes>#{changes}</m:Changes>
        </m:SyncFolderItemsResponseMessage>
      </m:ResponseMessages>
    </m:SyncFolderItemsResponse>
    """)
  end

  defp capture_bodies(response) do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      send(test_pid, {:request_body, body})
      xml(conn, response)
    end)
  end

  defp respond_in_sequence(responses, opts \\ []) do
    test_pid = self()
    counter = :counters.new(1, [])

    ReqTest.stub(:tymeslot_http, fn conn ->
      {:ok, body, conn} = Conn.read_body(conn)
      if opts[:capture], do: send(test_pid, {:request_body, body})

      :counters.add(counter, 1, 1)
      index = :counters.get(counter, 1) - 1

      xml(conn, Enum.at(responses, index) || List.last(responses))
    end)
  end

  defp xml(conn, body) do
    conn
    |> Conn.put_resp_content_type("text/xml")
    |> Conn.resp(200, body)
  end

  defp sent_body do
    assert_received {:request_body, body}
    body
  end

  defp sent_bodies(count), do: Enum.map(1..count, fn _index -> sent_body() end)
end
