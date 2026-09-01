defmodule Tymeslot.Integrations.Calendar.Exchange.Requests do
  @moduledoc """
  Builders for the EWS request bodies this provider issues.

  Each function returns the operation element only; wrapping it in a SOAP
  envelope is `Exchange.Soap.envelope/1`'s job.

  ## Why the read path is two calls

  `FindItem` cannot return an item's iCalendar `UID`: the property is silently
  dropped from `AdditionalProperties` rather than faulted, which was confirmed
  against a live server. `CalendarEvent` requires a stable non-empty `uid`, so
  `FindItem` is used purely to enumerate item ids over a `CalendarView`, and a
  single batched `GetItem` fetches the fields. `GetItem` accepts many ids and
  answers one response message per id, so the cost is two round trips per sync
  window regardless of how many events fall in it.

  `IncludeMimeContent` is deliberately never requested. It returns a base64
  MIME multipart message whose `text/calendar` part is quoted-printable
  encoded, so reaching the iCalendar inside costs a MIME parse and a QP decode
  to obtain fields that `BaseShape=Default` already returns as typed XML.

  ## Busy time comes from a different operation

  `FindItem` over a `CalendarView` does not expand a recurring series on every
  server. A grommunio mailbox answers one `RecurringMaster` dated to the
  series' first occurrence, and nothing at all for a window covering later
  ones, so the item path cannot see the third week of a weekly standup.
  `get_user_availability/3` is the operation that does expand it, and
  `Exchange.FreeBusy` reads its answer; the item path feeds the dashboard grid
  rather than availability.

  ## Paging is not implemented

  Neither builder requests an indexed page view, so `FindItem` returns at most
  the server's `FindCountLimit` worth of items and truncates the rest. Nothing
  reads `IncludesLastItemInRange` either, so a folder or sync window larger
  than that limit is silently short rather than an error: the response carries
  `IncludesLastItemInRange="false"` and the events past the cut simply never
  reach the caller. Paging is deliberately left out of this phase; adding it
  means an `m:IndexedPageItemView` on `find_item/3` and a loop driven by that
  attribute.
  """

  alias Tymeslot.Integrations.Calendar.Utils.XmlEscape

  @doc "Enumerates the mailbox's folders so calendars can be picked out."
  @spec find_folder() :: String.t()
  def find_folder do
    """
    <m:FindFolder Traversal="Deep">
      <m:FolderShape><t:BaseShape>Default</t:BaseShape></m:FolderShape>
      <m:ParentFolderIds><t:DistinguishedFolderId Id="msgfolderroot"/></m:ParentFolderIds>
    </m:FindFolder>
    """
  end

  @doc """
  Enumerates item ids in a calendar folder over a time range.

  `folder` is either `:calendar` (the mailbox's default calendar) or an EWS
  folder id string.
  """
  @spec find_item(:calendar | String.t(), DateTime.t(), DateTime.t()) :: String.t()
  def find_item(folder, %DateTime{} = from, %DateTime{} = to)
      when folder == :calendar or is_binary(folder) do
    """
    <m:FindItem Traversal="Shallow">
      <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>
      <m:CalendarView StartDate="#{calendar_view_time(from)}" EndDate="#{calendar_view_time(to)}"/>
      <m:ParentFolderIds>#{folder_element(folder)}</m:ParentFolderIds>
    </m:FindItem>
    """
  end

  @doc """
  Fetches the given items in one request.

  Takes `{item_id, change_key}` pairs as returned by `FindItem`, and requires
  at least one. An empty batch is a caller bug rather than a degenerate case
  to render: `m:ItemIds` demands a child, so the server would answer a schema
  fault to a request that could only ever have returned nothing. Callers skip
  the operation when the window is empty, and the guard makes forgetting that
  fail here rather than a round trip later.

  Two properties are asked for on top of `BaseShape=Default`, which returns
  neither: `calendar:IsCancelled`, so a cancelled meeting stops blocking the
  organiser's diary, and `calendar:StartTimeZone`, which is the only exact way
  to recover an all-day event's own calendar day. Asking is free against a
  server that does not implement them. Unsupported properties are dropped from
  the response rather than faulted, which was confirmed against a live
  grommunio server: it answers `NoError` and simply omits both elements, while
  a real Exchange server answers them. The normaliser therefore treats both as
  optional and gains correctness wherever they arrive.
  """
  @spec get_item([{String.t(), String.t()}, ...]) :: String.t()
  def get_item([_pair | _rest] = ids) do
    item_ids =
      Enum.map_join(ids, "\n", fn {id, change_key} ->
        ~s(<t:ItemId Id="#{XmlEscape.escape(id)}" ChangeKey="#{XmlEscape.escape(change_key)}"/>)
      end)

    """
    <m:GetItem>
      <m:ItemShape>
        <t:BaseShape>Default</t:BaseShape>
        <t:AdditionalProperties>
          <t:FieldURI FieldURI="calendar:IsCancelled"/>
          <t:FieldURI FieldURI="calendar:StartTimeZone"/>
        </t:AdditionalProperties>
      </m:ItemShape>
      <m:ItemIds>#{item_ids}</m:ItemIds>
    </m:GetItem>
    """
  end

  @doc """
  Asks for one mailbox's busy intervals over a window.

  `GetUserAvailability` is the only EWS operation that expands a recurring
  series, so it is what decides busy time; `Exchange.FreeBusy` parses the
  answer.

  The `t:TimeZone` block is not decoration. Omitting it, or sending a partial
  one, makes the server answer an empty body carrying no fault and no response
  code, which is indistinguishable from a free calendar unless the reader
  refuses to read it as one. A bias of zero with placeholder standard and
  daylight rules puts that zone on UTC, which is what the window boundaries
  below are shifted into and what the answer comes back in.

  `FreeBusy` is the view asked for rather than `Detailed`. The two return the
  same intervals with the same busy types, verified against a live server, and
  the server downgrades a `Detailed` request to `FreeBusy` anyway. `Detailed`
  differs only in asking a permissioned server for the meeting subjects,
  locations and item ids that `Exchange.FreeBusy` discards, so it costs
  mailbox content for nothing.

  `t:MergedFreeBusyIntervalInMinutes` is inert for that view: it sizes the
  merged bitmask only a `MergedOnly` view returns. It stays because the
  request verified against a live server carried it, and a schema deviation
  here is answered with an empty body and no fault, which is indistinguishable
  from a free calendar; trading a verified request for an unverified one to
  save a line is a bad bet.
  """
  @spec get_user_availability(String.t(), DateTime.t(), DateTime.t()) :: String.t()
  def get_user_availability(email, %DateTime{} = from, %DateTime{} = to)
      when is_binary(email) do
    """
    <m:GetUserAvailabilityRequest>
      <t:TimeZone>
        <t:Bias>0</t:Bias>
        <t:StandardTime>
          <t:Bias>0</t:Bias>
          <t:Time>00:00:00</t:Time>
          <t:DayOrder>1</t:DayOrder>
          <t:Month>1</t:Month>
          <t:DayOfWeek>Sunday</t:DayOfWeek>
        </t:StandardTime>
        <t:DaylightTime>
          <t:Bias>0</t:Bias>
          <t:Time>00:00:00</t:Time>
          <t:DayOrder>1</t:DayOrder>
          <t:Month>1</t:Month>
          <t:DayOfWeek>Sunday</t:DayOfWeek>
        </t:DaylightTime>
      </t:TimeZone>
      <m:MailboxDataArray>
        <t:MailboxData>
          <t:Email><t:Address>#{XmlEscape.escape(email)}</t:Address></t:Email>
          <t:AttendeeType>Required</t:AttendeeType>
        </t:MailboxData>
      </m:MailboxDataArray>
      <t:FreeBusyViewOptions>
        <t:TimeWindow>
          <t:StartTime>#{availability_window_time(from)}</t:StartTime>
          <t:EndTime>#{availability_window_time(to)}</t:EndTime>
        </t:TimeWindow>
        <t:MergedFreeBusyIntervalInMinutes>30</t:MergedFreeBusyIntervalInMinutes>
        <t:RequestedView>FreeBusy</t:RequestedView>
      </t:FreeBusyViewOptions>
    </m:GetUserAvailabilityRequest>
    """
  end

  defp folder_element(:calendar), do: ~s(<t:DistinguishedFolderId Id="calendar"/>)
  defp folder_element(id) when is_binary(id), do: ~s(<t:FolderId Id="#{XmlEscape.escape(id)}"/>)

  # `DateTime.to_iso8601/1` renders a UTC datetime with a `Z` suffix, which is
  # what a `CalendarView` bound wants: it is an absolute instant.
  defp calendar_view_time(datetime), do: datetime |> in_utc() |> DateTime.to_iso8601()

  # A `FreeBusyViewOptions` bound is the opposite: an unqualified local time,
  # read in whatever zone the request's `t:TimeZone` block names. That block
  # names UTC, so the instant is right, but a `Z` suffix on it is a schema
  # violation and the naive rendering is what drops it.
  defp availability_window_time(datetime) do
    datetime |> in_utc() |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
  end

  # The shift normalises the caller's zone away; a zoned bound would otherwise
  # be rendered with its own offset. Shifting to `Etc/UTC` needs no timezone
  # database.
  defp in_utc(datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
  end
end
