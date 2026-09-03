defmodule Tymeslot.ExchangeFixtures do
  @moduledoc """
  Canned EWS SOAP responses, shared by the provider and worker tests.

  These are trimmed transcripts of what a live server returned, not invented
  shapes: the element set matches what `GetItem` with `BaseShape=Default`
  actually answers, including the absence of `UID` from `FindItem`, and the
  free/busy body is the one `GetUserAvailability` sends, which does not nest
  under `m:ResponseMessages` the way every other operation does.

  They live here rather than in one test file because the provider and the
  sync worker both read them, and two copies of a response shape drift: the
  copy that stops matching the server keeps its test green.
  """

  import Tymeslot.ExchangeCase, only: [response_envelope: 2, soap_envelope: 1]

  @item_id "item-1"
  @change_key "ck-1"

  @doc """
  A `FindItem` response listing the given `{item_id, change_key}` pairs.

  `FindItem` is asked for `BaseShape=IdOnly`, so an id and a change key is
  genuinely all a real response carries here.
  """
  @spec find_item_response([{String.t(), String.t()}]) :: String.t()
  def find_item_response(ids \\ [{@item_id, @change_key}]) do
    items =
      Enum.map_join(ids, "\n", fn {id, change_key} ->
        ~s(<t:CalendarItem><t:ItemId Id="#{id}" ChangeKey="#{change_key}"/></t:CalendarItem>)
      end)

    response_envelope("FindItem", "<m:RootFolder><t:Items>#{items}</t:Items></m:RootFolder>")
  end

  @doc "A `FindItem` response over a range holding no events."
  @spec empty_find_item_response() :: String.t()
  def empty_find_item_response do
    response_envelope("FindItem", "<m:RootFolder><t:Items/></m:RootFolder>")
  end

  @doc """
  A response to `operation` whose single response message failed with `code`.

  Built by hand rather than through `response_envelope/2`, which always
  states `NoError`. A failed message carries no payload at all — no
  `m:RootFolder`, no `m:Items` — which is exactly the shape that reads as an
  empty calendar to anything not checking the response code.
  """
  @spec failed_response(String.t(), String.t()) :: String.t()
  def failed_response(operation, code) do
    soap_envelope("""
    <m:#{operation}Response>
        <m:ResponseMessages>
          #{failed_message(operation, code)}
        </m:ResponseMessages>
      </m:#{operation}Response>
    """)
  end

  @doc """
  A `GetItem` response carrying one timed event.

  `overrides` replaces any of `:id`, `:change_key`, `:subject`, `:uid`,
  `:start`, `:end` and `:calendar_item_type`; the last is omitted entirely
  unless given, matching a server that does not answer it.
  """
  @spec get_item_response(keyword()) :: String.t()
  def get_item_response(overrides \\ []) do
    response_envelope("GetItem", "<m:Items>#{calendar_item(overrides)}</m:Items>")
  end

  @doc """
  A `GetItem` response answering one response message per entry.

  `GetItem` states an outcome per requested id, so a real batch can be partly
  successful. An entry is `{:ok, overrides}` for a message carrying one
  calendar item (`overrides` as `get_item_response/1` takes them), or
  `{:error, code}` for one that failed and therefore carries no `m:Items`.
  """
  @spec get_item_batch_response([{:ok, keyword()} | {:error, String.t()}]) :: String.t()
  def get_item_batch_response(entries) do
    soap_envelope("""
    <m:GetItemResponse>
        <m:ResponseMessages>
          #{Enum.map_join(entries, "\n", &get_item_message/1)}
        </m:ResponseMessages>
      </m:GetItemResponse>
    """)
  end

  @doc "A `FindFolder` response listing the default Calendar folder."
  @spec find_folder_response() :: String.t()
  def find_folder_response do
    response_envelope("FindFolder", """
    <m:RootFolder><t:Folders>
                  <t:CalendarFolder>
                    <t:FolderId Id="cal-1" ChangeKey="fck-1"/>
                    <t:DisplayName>Calendar</t:DisplayName>
                  </t:CalendarFolder>
                </t:Folders></m:RootFolder>
    """)
  end

  @doc """
  A `GetUserAvailability` response carrying one busy interval per
  `{start_time, end_time}` pair.

  Its body sits directly under the operation element rather than under
  `m:ResponseMessages`, which is the shape a real server sends and the reason
  `Exchange.FreeBusy` cannot reuse `Soap.response_messages/2`.
  """
  @spec availability_response([{String.t(), String.t()}]) :: String.t()
  def availability_response(intervals \\ [{"2026-09-01T10:00:00Z", "2026-09-01T11:00:00Z"}]) do
    events =
      Enum.map_join(intervals, "\n", fn {start_at, end_at} ->
        """
        <t:CalendarEvent>
          <t:StartTime>#{start_at}</t:StartTime>
          <t:EndTime>#{end_at}</t:EndTime>
          <t:BusyType>Busy</t:BusyType>
        </t:CalendarEvent>
        """
      end)

    availability_envelope("""
    <m:FreeBusyResponseArray><m:FreeBusyResponse>
        <m:ResponseMessage ResponseClass="Success">
          <m:ResponseCode>NoError</m:ResponseCode>
        </m:ResponseMessage>
        <m:FreeBusyView>
          <t:FreeBusyViewType>FreeBusy</t:FreeBusyViewType>
          <t:CalendarEventArray>#{events}</t:CalendarEventArray>
        </m:FreeBusyView>
      </m:FreeBusyResponse></m:FreeBusyResponseArray>
    """)
  end

  @doc """
  The answer a server gives to a `GetUserAvailability` whose `t:TimeZone`
  block it could not use: an empty body, no fault, no response code.

  Indistinguishable from a free mailbox unless the reader refuses to read it
  as one, which is why it is a fixture rather than a hypothetical.
  """
  @spec empty_availability_response() :: String.t()
  def empty_availability_response, do: availability_envelope("")

  defp availability_envelope(body) do
    soap_envelope("<m:GetUserAvailabilityResponse>#{body}</m:GetUserAvailabilityResponse>")
  end

  defp get_item_message({:ok, overrides}) do
    """
    <m:GetItemResponseMessage ResponseClass="Success">
      <m:ResponseCode>NoError</m:ResponseCode>
      <m:Items>#{calendar_item(overrides)}</m:Items>
    </m:GetItemResponseMessage>
    """
  end

  defp get_item_message({:error, code}), do: failed_message("GetItem", code)

  defp failed_message(operation, code) do
    """
    <m:#{operation}ResponseMessage ResponseClass="Error">
      <m:ResponseCode>#{code}</m:ResponseCode>
    </m:#{operation}ResponseMessage>
    """
  end

  defp calendar_item(overrides) do
    fields =
      Keyword.merge(
        [
          id: @item_id,
          change_key: @change_key,
          subject: "Standup",
          uid: "uid-1",
          start: "2026-09-01T10:00:00Z",
          end: "2026-09-01T11:00:00Z",
          calendar_item_type: nil
        ],
        overrides
      )

    """
    <t:CalendarItem>
      <t:ItemId Id="#{fields[:id]}" ChangeKey="#{fields[:change_key]}"/>
      <t:Subject>#{fields[:subject]}</t:Subject>
      <t:UID>#{fields[:uid]}</t:UID>
      <t:Start>#{fields[:start]}</t:Start>
      <t:End>#{fields[:end]}</t:End>
      <t:IsAllDayEvent>false</t:IsAllDayEvent>
      <t:LegacyFreeBusyStatus>Busy</t:LegacyFreeBusyStatus>
      #{item_type_element(fields[:calendar_item_type])}
    </t:CalendarItem>
    """
  end

  defp item_type_element(nil), do: ""
  defp item_type_element(type), do: "<t:CalendarItemType>#{type}</t:CalendarItemType>"
end
