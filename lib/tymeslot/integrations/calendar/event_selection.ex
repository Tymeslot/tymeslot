defmodule Tymeslot.Integrations.Calendar.EventSelection do
  @moduledoc """
  Matches cached calendar events against an integration's settled calendar
  selection: whether an event is visible, which calendar entry it came from,
  whether it may be written back, and the per-integration visibility rules a
  query needs to apply the same filtering in SQL.

  `Tymeslot.Integrations.Calendar.Selection` owns the selection list itself
  (discovery merging, persistence) and delegates these event-facing questions
  here.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Selection

  @doc """
  Decides whether a cached calendar event belongs to a calendar the user
  currently has enabled.

  Returns `true` for legacy integrations that have no `calendar_list`
  populated — they predate per-calendar selection, so show everything.
  Otherwise picks the right matching signal for the event's provider:

  - CalDAV events (`provider_event_id` is a CalDAV href starting with `/`)
    match a selected calendar by **path prefix**. The href is rooted at the
    collection the event lives in, so it holds regardless of what
    `provider_calendar_id` says — including for rows written before that
    column was filed per calendar rather than per integration.
  - Other providers (Google, Outlook) tag every cached row with the
    originating calendar in `provider_calendar_id`, so match that against
    the selected entries' `id`.

  Returns `false` only when the integration has a `calendar_list` and the
  event does not match any selected entry — i.e. the user has explicitly
  deselected the calendar this event came from.
  """
  @spec event_visible?(map(), map()) :: boolean()
  def event_visible?(_event, %{calendar_list: nil}), do: true
  def event_visible?(_event, %{calendar_list: []}), do: true

  def event_visible?(event, %{calendar_list: calendar_list}) do
    case Selection.selected_calendars(calendar_list) do
      [] -> false
      selected -> not is_nil(calendar_for_event(event, selected))
    end
  end

  @doc """
  Keeps only the cached `events` the user can currently see, judged against the
  integration each came from (see `event_visible?/2`).

  Rows the previous sync wrote for a calendar the user has since deselected stay
  in the cache until pruning runs, so every surface that lists cached events has
  to filter them here to honour the selection immediately. An event whose
  integration is not in `integrations` is kept.
  """
  @spec visible_events([map()], [map()]) :: [map()]
  def visible_events(events, integrations) do
    integration_by_id = Map.new(integrations, &{&1.id, &1})

    Enum.filter(events, fn event ->
      case Map.fetch(integration_by_id, event.calendar_integration_id) do
        :error -> true
        {:ok, integration} -> event_visible?(event, integration)
      end
    end)
  end

  @typedoc """
  A single integration's visibility rule, in the shape a query builder can
  turn into a `where` clause: `:all` (no selection list, show everything),
  `:none` (a selection list with nothing selected, show nothing), or
  `{:selected, entries}` where each entry carries the `provider_calendar_id`
  to match non-CalDAV rows against (`:id`) and the href prefix to match
  CalDAV rows against (`:prefix`).
  """
  @type visibility_rule ::
          :all | :none | {:selected, [%{id: String.t() | nil, prefix: String.t() | nil}]}

  @doc """
  Derives, per integration id, the `t:visibility_rule/0` a SQL query needs to
  filter cached events the same way `visible_events/2` does in memory.

  This is the pure half of that filtering: it reads only `integration.id` and
  `integration.calendar_list`, and returns plain data a query module can turn
  into a `where` clause without depending on this module's types. It mirrors
  `event_visible?/2`'s dispatch exactly: nil/empty `calendar_list` is `:all`,
  a `calendar_list` with nothing selected is `:none`, otherwise the selected
  entries carry both matching signals `calendar_for_event/2` picks between
  (CalDAV path prefix vs `provider_calendar_id`), since which one applies is a
  property of the event, not the integration, and only the query layer sees
  the row.
  """
  @spec visibility_rules([map()]) :: %{integer() => visibility_rule()}
  def visibility_rules(integrations) do
    Map.new(integrations, fn integration ->
      {integration.id, integration_rule(integration, &Selection.selected_calendars/1)}
    end)
  end

  defp integration_rule(%{calendar_list: list}, _pick) when list in [nil, []], do: :all

  defp integration_rule(%{calendar_list: calendar_list}, pick),
    do: entries_rule(pick.(calendar_list))

  @doc """
  The `t:visibility_rule/0` matching cached rows from `entries`: `:none`
  for no entries.
  """
  @spec entries_rule([CalendarEntry.t()]) ::
          :none | {:selected, [%{id: String.t() | nil, prefix: String.t() | nil}]}
  def entries_rule([]), do: :none

  def entries_rule(entries),
    do: {:selected, Enum.map(entries, &%{id: &1.id, prefix: &1.path || &1.id})}

  @doc """
  Resolves the entry in `calendar_list` that `event` came from, or `nil` when
  no entry matches.

  Picks the same matching signal `event_visible?/2` documents: a CalDAV event
  (whose `provider_event_id` is an href rooted at its collection) matches by
  path prefix, everything else by the `provider_calendar_id` the sync tagged
  the row with. Callers asking a per-calendar question about an event (is it
  visible, is it writable, which calendar does it sit on) must go through here
  rather than re-deriving the match, since the two signals disagree on CalDAV
  and neither an organiser's address nor a default calendar identifies the
  calendar an event was synced from.
  """
  @spec calendar_for_event(map(), [CalendarEntry.t()] | nil) :: CalendarEntry.t() | nil
  def calendar_for_event(_event, nil), do: nil

  def calendar_for_event(event, calendar_list) when is_list(calendar_list) do
    if caldav_event?(event) do
      Selection.find_calendar_by_path(calendar_list, event.provider_event_id)
    else
      case Map.get(event, :provider_calendar_id) do
        pcid when is_binary(pcid) -> find_calendar_by_id(calendar_list, pcid)
        _untagged -> nil
      end
    end
  end

  @doc """
  Decides whether an event cached from `integration` sits on a calendar the
  provider will accept writes to.

  Two independent things can make it read-only, and both have to be asked:

    * the provider itself refuses every write (`ProviderConfig.read_only?/1` —
      a subscribed ICS feed, which has no write protocol at all), so no
      calendar under it is writable; and
    * the individual calendar the event came from is read-only, which is
      ordinary on an otherwise writable provider: a Google calendar shared
      with `reader` access, an Outlook calendar reporting `canEdit == false`,
      a CalDAV collection without the write privilege.

  An event whose originating calendar cannot be resolved counts as writable.
  Legacy rows predating per-calendar tagging match no entry, and refusing to
  edit those would break editing on ordinary calendars; the provider-level
  check still covers the wholly read-only providers.
  """
  @spec event_writable?(map(), %{
          :provider => atom() | String.t() | nil,
          :calendar_list => [CalendarEntry.t()] | nil,
          optional(atom()) => term()
        }) :: boolean()
  def event_writable?(event, %{provider: provider, calendar_list: calendar_list}) do
    not ProviderConfig.read_only?(provider) and not read_only_calendar?(event, calendar_list)
  end

  defp read_only_calendar?(event, calendar_list) do
    case calendar_for_event(event, calendar_list) do
      nil -> false
      entry -> entry.read_only
    end
  end

  defp caldav_event?(%{provider_event_id: peid}) when is_binary(peid),
    do: String.starts_with?(peid, "/")

  defp caldav_event?(_event), do: false

  defp find_calendar_by_id(calendar_list, id) when is_list(calendar_list) do
    Enum.find(calendar_list, &(&1.id == id))
  end
end
