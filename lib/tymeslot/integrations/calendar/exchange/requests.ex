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

  ## The write path addresses items by id, never by uid

  EWS assigns a calendar item's iCalendar `UID` itself, and a `t:UID` sent on
  `CreateItem` is ignored; that was verified against a live server. So a write
  cannot choose the handle it will use later. `create_item/2` answers the
  server's `ItemId`, which the provider hands back as the created event's `id`
  and which `Meetings.CalendarEventSync` persists as `provider_event_id`;
  `update_item/2` and `delete_item/1` take that id back.

  The change key is deliberately never sent. `UpdateItem` and `DeleteItem`
  naming an `ItemId` with no `ChangeKey` act on the item's current version,
  and the id itself survives an update unchanged, both verified against a live
  server. Threading a version stamp through would cost a `GetItem` before every
  write to refresh it, and buy a conflict check no caller here can act on: a
  booking write-back is the authority on the meeting it describes.

  ## Writes never invite anyone

  Every write carries `SendMeetingInvitations="SendToNone"` (or the
  cancellation equivalent) and no attendee elements at all. Tymeslot sends its
  own invitation and cancellation emails, so an item carrying attendees would
  have the Exchange server mail the same people a second time. This is the same
  trap `CalendarEventBuilder` documents for CalDAV, where the defence is
  `SCHEDULE-AGENT=CLIENT` on the `ORGANIZER` line; here it is an item with no
  attendees on it. The attendee's name and address still reach the organiser's
  diary, in the description `CalendarEventBuilder` assembles.

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

  @typedoc """
  The item a write describes, in this provider's own terms.

  `start_time`/`end_time` are `DateTime`s for a timed item and `Date`s for an
  all-day one, and both bounds must be the same shape. An all-day `end_time`
  is **inclusive**: the exclusive boundary EWS wants is derived here, so a
  one-day event is given the day it falls on rather than the next one.

  Every optional key is meaningful when absent and when `nil`, and the two mean
  different things on an update: a key the caller omitted is left alone on the
  server, and one carrying `nil` is cleared. `create_item/2` cannot tell them
  apart, because an absent field on a new item is an empty one either way.
  """
  @type item_spec :: %{
          optional(:summary) => String.t() | nil,
          required(:start_time) => DateTime.t() | Date.t(),
          required(:end_time) => DateTime.t() | Date.t(),
          optional(:description) => String.t() | nil,
          optional(:location) => String.t() | nil,
          optional(:transparency) => :opaque | :transparent,
          optional(:reminder_minutes) => non_neg_integer() | nil,
          optional(:recurrence) => %{
            required(:freq) => :daily,
            required(:interval) => pos_integer(),
            required(:count) => pos_integer()
          }
        }

  @doc """
  Creates one calendar item in a folder.

  `folder` is either `:calendar` (the mailbox's default calendar) or an EWS
  folder id string, exactly as `find_item/3` takes it.

  Child order is the EWS schema's own sequence for `t:CalendarItem`, which is
  validated: an element out of order is answered with a schema fault rather
  than ignored. The reminder pair belongs to `t:Item` and therefore precedes
  `t:Start`, which belongs to `t:CalendarItem`; that ordering was verified
  against a live server. Keep additions in schema order.
  """
  @spec create_item(item_spec(), :calendar | String.t()) :: String.t()
  def create_item(spec, folder \\ :calendar) when is_map(spec) do
    """
    <m:CreateItem SendMeetingInvitations="SendToNone">
      <m:SavedItemFolderId>#{folder_element(folder)}</m:SavedItemFolderId>
      <m:Items>
        <t:CalendarItem>
          #{element("t:Subject", spec[:summary])}
          #{body_element(spec[:description])}
          #{reminder_elements(spec)}
          #{timing_elements(spec)}
          <t:LegacyFreeBusyStatus>#{free_busy_status(spec[:transparency])}</t:LegacyFreeBusyStatus>
          #{element("t:Location", spec[:location])}
          #{recurrence_element(spec[:recurrence], spec[:start_time])}
        </t:CalendarItem>
      </m:Items>
    </m:CreateItem>
    """
  end

  @doc """
  Rewrites the fields of one existing item.

  `ConflictResolution="AlwaysOverwrite"` with no change key sent: see the
  moduledoc for why this provider does not carry a version stamp.

  A key the spec omits is not mentioned in the request at all, so the server
  leaves that field as it stands. A key carrying `nil` becomes a
  `t:DeleteItemField`, which is the only way to clear a field: a
  `t:SetItemField` carrying an empty element is a schema violation, and
  omitting the field silently leaves the old value in the organiser's diary.
  A meeting that loses its location on a reschedule would otherwise keep
  showing the old room.

  The timing bounds are the exception: they are written as a pair or not at
  all, because an all-day item's `t:IsAllDayEvent` has to move with them.
  """
  @spec update_item(String.t(), item_spec()) :: String.t()
  def update_item(item_id, spec) when is_binary(item_id) and is_map(spec) do
    """
    <m:UpdateItem ConflictResolution="AlwaysOverwrite"
                  SendMeetingInvitationsOrCancellations="SendToNone">
      <m:ItemChanges>
        <t:ItemChange>
          <t:ItemId Id="#{XmlEscape.escape(item_id)}"/>
          <t:Updates>#{updates(spec)}</t:Updates>
        </t:ItemChange>
      </m:ItemChanges>
    </m:UpdateItem>
    """
  end

  @doc """
  Removes one item.

  `HardDelete` rather than `MoveToDeletedItems`: an item in Deleted Items is
  still in the mailbox, so a later read of the whole mailbox would find every
  cancelled booking still sitting there.
  """
  @spec delete_item(String.t()) :: String.t()
  def delete_item(item_id) when is_binary(item_id) do
    """
    <m:DeleteItem DeleteType="HardDelete" SendMeetingCancellations="SendToNone">
      <m:ItemIds><t:ItemId Id="#{XmlEscape.escape(item_id)}"/></m:ItemIds>
    </m:DeleteItem>
    """
  end

  @doc """
  Asks a folder for the changes since a sync state token.

  `sync_state` is the opaque token the previous call answered, or `nil` for the
  first call against a folder, which enumerates everything in it as `Create`
  changes.

  ## This operation has no time window

  Unlike `find_item/3`, `SyncFolderItems` takes no `CalendarView` and answers
  for the **whole folder**, however far outside the sync window an item falls.
  Bounding the result to the window is therefore the caller's job, after the
  fields are fetched; see `Exchange.ItemSync`.

  ## A token the server cannot read fails open

  A malformed or foreign token is not refused. A live server answered
  `NoError` to a token of arbitrary bytes and treated the request as though no
  token had been sent, re-enumerating the folder from scratch. That is the
  safe direction to fail — a full re-read rather than a silent "nothing
  changed" — and it is why nothing here tries to validate a stored token
  before sending it.
  """
  @spec sync_folder_items(:calendar | String.t(), String.t() | nil, pos_integer()) :: String.t()
  def sync_folder_items(folder, sync_state, max_changes)
      when (folder == :calendar or is_binary(folder)) and is_integer(max_changes) and
             max_changes > 0 do
    """
    <m:SyncFolderItems>
      <m:ItemShape><t:BaseShape>IdOnly</t:BaseShape></m:ItemShape>
      <m:SyncFolderId>#{folder_element(folder)}</m:SyncFolderId>
      #{sync_state_element(sync_state)}
      <m:MaxChangesReturned>#{max_changes}</m:MaxChangesReturned>
    </m:SyncFolderItems>
    """
  end

  # --- Write-body fragments ---

  defp sync_state_element(nil), do: ""

  defp sync_state_element(state) when is_binary(state),
    do: "<m:SyncState>#{XmlEscape.escape(state)}</m:SyncState>"

  # The order the fragments are emitted in does not matter to the server here:
  # `t:Updates` is a repeating choice rather than a sequence, so unlike the
  # `t:CalendarItem` body above it imposes no schema order on its children.
  defp updates(spec) do
    Enum.map_join(
      [
        field_update(spec, :summary, "item:Subject", &subject_value/1),
        field_update(spec, :description, "item:Body", &body_value/1),
        field_update(spec, :location, "calendar:Location", &location_value/1),
        field_update(spec, :transparency, "calendar:LegacyFreeBusyStatus", &status_value/1),
        reminder_update(spec),
        timing_update(spec)
      ],
      "\n",
      & &1
    )
  end

  # `Map.fetch/2` rather than `spec[key]`: an absent key and a `nil` one are
  # different instructions here, and only `fetch` tells them apart.
  defp field_update(spec, key, field_uri, value_fun) do
    case Map.fetch(spec, key) do
      :error -> ""
      {:ok, nil} -> delete_item_field(field_uri)
      {:ok, value} -> set_item_field(field_uri, value_fun.(value))
    end
  end

  defp subject_value(value), do: element("t:Subject", value)
  defp location_value(value), do: element("t:Location", value)
  defp body_value(value), do: body_element(value)

  defp status_value(value),
    do: "<t:LegacyFreeBusyStatus>#{free_busy_status(value)}</t:LegacyFreeBusyStatus>"

  # Written as a pair so `t:IsAllDayEvent` can never disagree with the bounds
  # it describes: an all-day meeting rescheduled to a timed one would
  # otherwise keep the flag and be read back as covering whole days.
  defp timing_update(%{start_time: _start, end_time: _end} = spec) do
    Enum.map_join(timing_pairs(spec), "\n", fn {field_uri, fragment} ->
      set_item_field(field_uri, fragment)
    end)
  end

  defp timing_update(_spec), do: ""

  defp timing_pairs(spec) do
    {from, to} = timing_bounds(spec)

    [
      {"calendar:Start", "<t:Start>#{from}</t:Start>"},
      {"calendar:End", "<t:End>#{to}</t:End>"},
      {"calendar:IsAllDayEvent", "<t:IsAllDayEvent>#{all_day?(spec)}</t:IsAllDayEvent>"}
    ]
  end

  defp reminder_update(spec) do
    case Map.fetch(spec, :reminder_minutes) do
      :error ->
        ""

      {:ok, nil} ->
        set_item_field("item:ReminderIsSet", "<t:ReminderIsSet>false</t:ReminderIsSet>")

      {:ok, minutes} ->
        Enum.join(
          [
            set_item_field("item:ReminderIsSet", "<t:ReminderIsSet>true</t:ReminderIsSet>"),
            set_item_field(
              "item:ReminderMinutesBeforeStart",
              "<t:ReminderMinutesBeforeStart>#{minutes}</t:ReminderMinutesBeforeStart>"
            )
          ],
          "\n"
        )
    end
  end

  defp set_item_field(field_uri, fragment) do
    """
    <t:SetItemField>
      <t:FieldURI FieldURI="#{field_uri}"/>
      <t:CalendarItem>#{fragment}</t:CalendarItem>
    </t:SetItemField>
    """
  end

  defp delete_item_field(field_uri) do
    ~s(<t:DeleteItemField><t:FieldURI FieldURI="#{field_uri}"/></t:DeleteItemField>)
  end

  defp reminder_elements(spec) do
    case spec[:reminder_minutes] do
      nil ->
        ""

      minutes ->
        """
        <t:ReminderIsSet>true</t:ReminderIsSet>
        <t:ReminderMinutesBeforeStart>#{minutes}</t:ReminderMinutesBeforeStart>
        """
    end
  end

  defp timing_elements(spec) do
    {from, to} = timing_bounds(spec)

    """
    <t:Start>#{from}</t:Start>
    <t:End>#{to}</t:End>
    <t:IsAllDayEvent>#{all_day?(spec)}</t:IsAllDayEvent>
    """
  end

  # An all-day item's bounds are still sent as instants, with the exclusive end
  # EWS shares with iCalendar: a one-day event ends at the next midnight. The
  # callers pass an inclusive end date, so the +1 is applied here rather than
  # expected of them, matching what `Diagnostics.normalise_event_attrs/1` does
  # for every other provider.
  defp timing_bounds(%{start_time: %Date{} = from, end_time: %Date{} = to}),
    do: {midnight_utc(from), midnight_utc(Date.add(to, 1))}

  defp timing_bounds(%{start_time: %DateTime{} = from, end_time: %DateTime{} = to}),
    do: {utc_instant(from), utc_instant(to)}

  defp all_day?(%{start_time: %Date{}}), do: true
  defp all_day?(_spec), do: false

  # `Free` is the only value that leaves the organiser bookable, which is what
  # `Exchange.EventNormaliser.map_transparency/1` reads back.
  defp free_busy_status(:transparent), do: "Free"
  defp free_busy_status(_other), do: "Busy"

  defp recurrence_element(nil, _start_time), do: ""

  defp recurrence_element(%{freq: :daily, interval: interval, count: count}, start_time) do
    """
    <t:Recurrence>
      <t:DailyRecurrence><t:Interval>#{interval}</t:Interval></t:DailyRecurrence>
      <t:NumberedRecurrence>
        <t:StartDate>#{Date.to_iso8601(series_start_date(start_time))}</t:StartDate>
        <t:NumberOfOccurrences>#{count}</t:NumberOfOccurrences>
      </t:NumberedRecurrence>
    </t:Recurrence>
    """
  end

  defp body_element(nil), do: ""

  defp body_element(description),
    do: ~s(<t:Body BodyType="Text">#{XmlEscape.escape(description)}</t:Body>)

  defp element(_name, nil), do: ""
  defp element(name, value), do: "<#{name}>#{XmlEscape.escape(value)}</#{name}>"

  # The recurrence range is bounded by a calendar day, whichever shape the
  # spec's start carries: a timed series starts on the day its first
  # occurrence falls on.
  defp series_start_date(%Date{} = date), do: date
  defp series_start_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)

  defp midnight_utc(%Date{} = date),
    do: date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()

  defp utc_instant(%DateTime{} = datetime), do: datetime |> in_utc() |> DateTime.to_iso8601()

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
