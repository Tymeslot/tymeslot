defmodule Tymeslot.Integrations.Calendar.Exchange.Seeding do
  @moduledoc """
  Diagnostic-only EWS writes, used to plant and remove audit fixtures.

  `Exchange.Provider` is read-only and must stay that way: its `create_event/2`,
  `update_event/3` and `delete_event/3` answer `{:error, :read_only}`, an
  Exchange folder is persisted `read_only: true`, and `ProviderConfig.read_only?/1`
  keeps such an integration out of every booking-target list. None of that is
  softened here. This module is not a `Provider` callback, is not reachable from
  one, and is called from exactly one place: `Calendar.Diagnostics`, on behalf of
  `mix calendar_audit`.

  It exists because auditing a read-only provider still needs something on the
  server to read. Every other provider the audit covers plants its own fixture
  through the write path it is being audited for; Exchange has no such path, so
  the fixture is planted out of band, by the same SOAP transport the read path
  uses, and removed again in the same run.

  ## Why not seed over another protocol

  grommunio, the container the audit is developed against, also speaks CalDAV,
  so a fixture could be planted with the CalDAV writer that already exists. It
  is not, for two reasons. A real Exchange Server offers no such side door, so
  `--exchange` would work only against the lab. And a fixture planted over
  CalDAV audits grommunio's CalDAV-to-MAPI conversion rather than the EWS
  representation the provider actually reads.

  ## The item id is the handle, not the UID

  EWS assigns a calendar item's iCalendar `UID` itself; a `t:UID` sent on
  `CreateItem` is ignored, verified against a live server. What comes back is
  an item id, which is what `Exchange.EventNormaliser` writes into
  `provider_event_id`. Callers therefore correlate a seeded item by item id,
  never by a uid they chose.

  The change key that arrives beside it is deliberately dropped. Nothing here
  edits a fixture, and `DeleteItem` naming an id alone removes the item's
  current version, which was verified against a live server. Carrying a version
  stamp no caller can act on would only invite one to be threaded through the
  audit and go stale.
  """

  # Only the sigil: every xpath goes through `Soap.xpath/2,3`, which binds the
  # EWS namespace prefixes onto the spec and onto every subspec.
  import SweetXml, only: [sigil_x: 2]

  alias Tymeslot.Integrations.Calendar.Exchange.Client
  alias Tymeslot.Integrations.Calendar.Exchange.Requests
  alias Tymeslot.Integrations.Calendar.Exchange.Soap

  @typedoc "The handle a seeded item is addressed by afterwards."
  @type item_id :: String.t()

  @typedoc """
  A fixture to plant.

  `start_time`/`end_time` are `DateTime`s for a timed event and `Date`s for an
  all-day one, matching the shape `mix calendar_audit` scenarios already carry.
  `recurrence` is EWS-shaped rather than an RRULE, because nothing in this
  codebase converts one to the other and the audit's only recurring Exchange
  fixture is a simple daily count.
  """
  @type fixture :: %{
          required(:summary) => String.t(),
          required(:start_time) => DateTime.t() | Date.t(),
          required(:end_time) => DateTime.t() | Date.t(),
          optional(:description) => String.t() | nil,
          optional(:location) => String.t() | nil,
          optional(:transparency) => :opaque | :transparent,
          optional(:recurrence) => %{
            required(:freq) => :daily,
            required(:interval) => pos_integer(),
            required(:count) => pos_integer()
          }
        }

  @doc """
  Plants one calendar item in the mailbox's default calendar folder.

  Meeting invitations are suppressed: a fixture carries no attendees, and a
  server that decided to send one anyway would mail a real person from an audit
  run.
  """
  @spec create_item(Client.config(), fixture()) :: {:ok, item_id()} | {:error, term()}
  def create_item(config, fixture) when is_map(fixture) do
    with {:ok, doc} <- Client.call(config, create_item_body(fixture)),
         {:ok, messages} <- Soap.require_success(doc, "CreateItemResponseMessage") do
      created_id(messages)
    end
  end

  @doc """
  Removes a seeded item.

  `HardDelete` rather than `MoveToDeletedItems`: a fixture in the Deleted Items
  folder is still in the mailbox, and a later audit run reading the whole
  mailbox would find the leftovers of every earlier one.
  """
  @spec delete_item(Client.config(), item_id()) :: :ok | {:error, term()}
  def delete_item(config, item_id) when is_binary(item_id) do
    with {:ok, doc} <- Client.call(config, delete_item_body(item_id)),
         {:ok, _messages} <- Soap.require_success(doc, "DeleteItemResponseMessage") do
      :ok
    end
  end

  # A success message carrying no id is not a success this caller can use: the
  # fixture is on the server and nothing can address it to read or remove it.
  # Saying so beats answering `{:ok, {nil, nil}}` and failing at the delete.
  defp created_id(messages) do
    case Enum.find_value(messages, &id_in/1) do
      nil -> {:error, :no_item_id}
      id -> {:ok, id}
    end
  end

  defp id_in(message) do
    Soap.text(message, ~x"./m:Items/t:CalendarItem/t:ItemId/@Id")
  end

  # ---------------------------------------------------------------------------
  # Request bodies
  #
  # Child order is the EWS schema's own sequence for `t:CalendarItem`, which is
  # validated: an element out of order is answered with a schema fault rather
  # than ignored. Keep additions in schema order.
  # ---------------------------------------------------------------------------

  defp create_item_body(fixture) do
    """
    <m:CreateItem SendMeetingInvitations="SendToNone">
      <m:SavedItemFolderId><t:DistinguishedFolderId Id="calendar"/></m:SavedItemFolderId>
      <m:Items>
        <t:CalendarItem>
          #{element("t:Subject", fixture[:summary])}
          #{body_element(fixture[:description])}
          #{timing_elements(fixture)}
          <t:LegacyFreeBusyStatus>#{free_busy_status(fixture[:transparency])}</t:LegacyFreeBusyStatus>
          #{element("t:Location", fixture[:location])}
          #{recurrence_element(fixture[:recurrence], fixture[:start_time])}
        </t:CalendarItem>
      </m:Items>
    </m:CreateItem>
    """
  end

  defp delete_item_body(item_id) do
    """
    <m:DeleteItem DeleteType="HardDelete" SendMeetingCancellations="SendToNone">
      <m:ItemIds><t:ItemId Id="#{Requests.escape(item_id)}"/></m:ItemIds>
    </m:DeleteItem>
    """
  end

  # An all-day event's bounds are still sent as instants, with the exclusive
  # end EWS shares with iCalendar: a one-day event ends at the next midnight.
  # The audit's own all-day scenarios pass an inclusive end date, so the +1 is
  # applied here rather than expected from the caller, matching what
  # `Diagnostics.normalise_event_attrs/1` does for every other provider.
  defp timing_elements(%{start_time: %Date{} = from, end_time: %Date{} = to}) do
    """
    <t:Start>#{midnight_utc(from)}</t:Start>
    <t:End>#{midnight_utc(Date.add(to, 1))}</t:End>
    <t:IsAllDayEvent>true</t:IsAllDayEvent>
    """
  end

  defp timing_elements(%{start_time: %DateTime{} = from, end_time: %DateTime{} = to}) do
    """
    <t:Start>#{utc_instant(from)}</t:Start>
    <t:End>#{utc_instant(to)}</t:End>
    <t:IsAllDayEvent>false</t:IsAllDayEvent>
    """
  end

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
        <t:StartDate>#{Date.to_iso8601(to_date(start_time))}</t:StartDate>
        <t:NumberOfOccurrences>#{count}</t:NumberOfOccurrences>
      </t:NumberedRecurrence>
    </t:Recurrence>
    """
  end

  defp body_element(nil), do: ""

  defp body_element(description),
    do: ~s(<t:Body BodyType="Text">#{Requests.escape(description)}</t:Body>)

  defp element(_name, nil), do: ""
  defp element(name, value), do: "<#{name}>#{Requests.escape(value)}</#{name}>"

  defp to_date(%Date{} = date), do: date
  defp to_date(%DateTime{} = datetime), do: DateTime.to_date(datetime)

  defp midnight_utc(%Date{} = date),
    do: date |> DateTime.new!(~T[00:00:00], "Etc/UTC") |> DateTime.to_iso8601()

  defp utc_instant(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end
end
