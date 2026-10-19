defmodule Tymeslot.Integrations.Calendar.Selection do
  @moduledoc """
  Business logic for calendar discovery/selection merging and preparing params
  for persistence.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Integrations.Calendar.BookingEligibility
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarSelectionQueries
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.RemovedCalendars
  alias Tymeslot.Utils.UriUtils

  @doc """
  Build the params fragment based on selected calendar paths and discovered items.

  - selected_paths: list of strings
  - discovered: list of calendars with at least path/name/type keys (string or atom keys)

  Returns a map suitable for merging into creation/update params:
    %{calendar_paths: ["a", "b", "c"], calendar_list: [%CalendarEntry{...}]}
  """
  @spec prepare_selected_params([String.t()], list()) ::
          %{required(String.t()) => [String.t()] | [CalendarEntry.t()]}
  def prepare_selected_params(selected_paths, discovered) when is_list(selected_paths) do
    calendar_paths = selected_paths

    selected_calendar_info =
      discovered
      |> Enum.map(&CalendarEntry.normalize/1)
      |> Enum.map(&CalendarEntry.with_defaults/1)
      |> Enum.filter(fn entry ->
        # Match against either path or id — CalDAV discovery emits only `id`
        # (the href), so a path-only filter would silently drop those entries.
        path_in_selected?(entry.path, selected_paths)
      end)
      |> Enum.map(&%{&1 | selected: true})

    %{"calendar_paths" => calendar_paths, "calendar_list" => selected_calendar_info}
  end

  @doc """
  Merge discovered calendars with an existing list of selections.

  A calendar already in `existing_list` keeps the owner's choices, whether it
  is selected and whether it blocks availability. A new one arrives
  deselected, with the blocking default its discovery gave it.
  """
  @spec unify_discovered_with_existing(list(), list()) :: [CalendarEntry.t()]
  def unify_discovered_with_existing(discovered, existing_list) do
    existing_map = build_existing_selection_map(existing_list)

    discovered
    |> Enum.map(&CalendarEntry.normalize/1)
    # CalDAV's XML discovery only emits `id` (the href). Fall back so we
    # always persist a usable path rather than `null`.
    |> Enum.map(&CalendarEntry.with_defaults/1)
    |> Enum.map(fn entry ->
      case lookup_choices(existing_map, [entry.path, entry.id]) do
        nil -> %{entry | selected: false}
        choices -> Map.merge(entry, choices)
      end
    end)
  end

  @doc """
  `calendar_list` with each calendar that `existing_list` already knows
  keeping the owner's blocking choice, for a write that rebuilds the list
  from a fresh discovery with a selection made anew (a reconnect). A
  calendar `existing_list` does not know keeps the default its discovery
  gave it.
  """
  @spec carry_blocking_choices([CalendarEntry.t()], list() | nil) :: [CalendarEntry.t()]
  def carry_blocking_choices(calendar_list, existing_list) do
    existing_map = build_existing_selection_map(existing_list || [])

    Enum.map(calendar_list, fn entry ->
      case lookup_choices(existing_map, [entry.path, entry.id]) do
        nil -> entry
        %{blocks_availability: blocks} -> %{entry | blocks_availability: blocks}
      end
    end)
  end

  defp build_existing_selection_map(existing) do
    Enum.reduce(existing, %{}, fn cal, acc ->
      entry = CalendarEntry.normalize(cal)
      choices = Map.take(entry, [:selected, :blocks_availability])

      acc
      |> maybe_put(entry.path, choices)
      |> maybe_put(entry.id, choices)
      |> maybe_put_decoded(entry.path, choices)
      |> maybe_put_decoded(entry.id, choices)
    end)
  end

  defp path_in_selected?(path, selected_paths) do
    Enum.any?(selected_paths, &UriUtils.uri_safe_match?(path, &1))
  end

  # Looks up the stored choices for a calendar identified by any of the given
  # keys (tried in order, each also percent-decoded), or nil for a calendar
  # the existing list does not know.
  defp lookup_choices(existing_map, keys) do
    keys
    |> Enum.flat_map(fn
      nil -> []
      key -> [key, UriUtils.safe_decode(key)]
    end)
    |> Enum.find_value(&Map.get(existing_map, &1))
  end

  defp maybe_put(acc, nil, _val), do: acc
  defp maybe_put(acc, key, val), do: Map.put(acc, key, val)

  defp maybe_put_decoded(acc, nil, _val), do: acc

  defp maybe_put_decoded(acc, key, val) do
    decoded = UriUtils.safe_decode(key)
    if decoded == key, do: acc, else: Map.put(acc, decoded, val)
  end

  @doc """
  Merges freshly `discovered` calendars into the integration's selection and
  persists the result, returning the updated integration and the merged list.

  The merge is made against the row as it stands once discovery is back, not
  against the struct discovery started from: discovery spends seconds on the
  network, and a calendar the owner ticked or unticked meanwhile must keep
  their choice. A merge that would empty a selection that was not empty
  keeps the stored list instead (see `keep_selection_if_emptied/2`).

  A selected calendar the discovery no longer returns is dropped from the
  list, and so recorded as removed and emailed about (see
  `Tymeslot.Integrations.Calendar.RemovedCalendars`). A discovery that
  failed never reaches this function.
  """
  @spec persist_discovered(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          list()
        ) ::
          {:ok,
           {Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(), [CalendarEntry.t()]}}
          | {:error, any()}
  def persist_discovered(%{id: id}, discovered) do
    result =
      CalendarSelectionQueries.with_locked(id, fn fresh ->
        merged =
          discovered
          |> unify_discovered_with_existing(fresh.calendar_list)
          |> keep_selection_if_emptied(fresh.calendar_list)

        with {:ok, updated} <- write_selection(fresh, calendar_list_attrs(merged)) do
          {:ok, {updated, merged, blocking_ids(fresh.calendar_list) != blocking_ids(merged)}}
        end
      end)

    case result do
      # A calendar that stopped blocking (gone from the provider) frees its
      # slots at once rather than after the cache expires.
      {:ok, {updated, merged, blocking_changed?}} ->
        if blocking_changed?, do: invalidate_after_commit({:ok, updated})
        {:ok, {updated, merged}}

      error ->
        error
    end
  end

  defp blocking_ids(calendar_list),
    do: calendar_list |> blocking_calendars() |> Enum.map(& &1.id) |> Enum.sort()

  # `calendar_paths` is derived from the `selected` flags on `calendar_list`, so
  # a re-discovery that matches nothing — an empty result, or a server that
  # changed the shape of the hrefs it returns — silently deselects everything
  # and leaves the integration syncing no calendars at all. Discovery is
  # triggered by opening a meeting-type form, so this can happen without the
  # owner touching their calendar settings. Keep the stored list whenever the
  # merge would empty a selection that was not empty before; deselecting every
  # calendar deliberately still works, because that goes through
  # `persist_calendar_list/2` directly rather than through discovery.
  defp keep_selection_if_emptied(merged, existing) do
    if derive_selected_paths(merged) == [] and derive_selected_paths(existing || []) != [] do
      existing
    else
      merged
    end
  end

  @doc """
  Deselects the calendars `calendar_ids` of `integration` that the provider
  answered as gone (HTTP 404), on the row as it stands, recording them as
  removed and scheduling the email about them in the same transaction (see
  `Tymeslot.Integrations.Calendar.RemovedCalendars`). A calendar that stopped
  blocking frees its slots at once.
  """
  @spec deselect_missing(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          [String.t()]
        ) ::
          {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :not_found | term()}
  def deselect_missing(%{id: id}, calendar_ids) do
    ids = MapSet.new(calendar_ids)

    id
    |> CalendarSelectionQueries.with_locked(fn fresh ->
      calendar_list =
        Enum.map(fresh.calendar_list, fn cal ->
          if MapSet.member?(ids, cal.id), do: %{cal | selected: false}, else: cal
        end)

      write_selection(fresh, %{calendar_list: calendar_list})
    end)
    |> invalidate_after_commit()
  end

  @doc """
  `deselect_missing/2` for CalDAV collections, by path: removes them from
  `calendar_paths` too, since pruning paths alone would leave them selected,
  failing booking pages closed.
  """
  @spec remove_missing_paths(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          [String.t()]
        ) ::
          {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()}
          | {:error, Ecto.Changeset.t() | :not_found | term()}
  def remove_missing_paths(%{id: id}, paths) do
    gone? = fn path -> Enum.any?(paths, &UriUtils.uri_safe_match?(&1, path)) end

    id
    |> CalendarSelectionQueries.with_locked(fn fresh ->
      calendar_list =
        Enum.map(fresh.calendar_list || [], fn cal ->
          if gone?.(cal.path || cal.id), do: %{cal | selected: false}, else: cal
        end)

      write_selection(fresh, %{
        calendar_paths: Enum.reject(fresh.calendar_paths || [], gone?),
        calendar_list: calendar_list
      })
    end)
    |> invalidate_after_commit()
  end

  # The one write of a selection that can drop calendars the server stopped
  # listing: what it deselects is recorded on the row it deselects them on,
  # merged into what `fresh` (read under the row lock) already records, and
  # the email is scheduled in the same transaction. A retry finds them
  # already deselected and records and sends nothing.
  defp write_selection(fresh, attrs) do
    removed = RemovedCalendars.removed(fresh.calendar_list, attrs.calendar_list)
    recorded = RemovedCalendars.merge(fresh.removed_calendars, removed, DateTime.utc_now())

    with {:ok, updated} <- CalendarSelectionQueries.update_selection(fresh, attrs, recorded),
         :ok <- RemovedCalendars.notify(fresh, removed) do
      {:ok, updated}
    end
  end

  # Dropped once the write commits, never inside a caller's transaction,
  # where a read in between would cache the old answer again.
  defp invalidate_after_commit({:ok, %{user_id: user_id}} = ok) do
    unless CalendarIntegrationQueries.in_transaction?(),
      do: Availability.changed(user_id)

    ok
  end

  defp invalidate_after_commit(error), do: error

  @doc """
  Persists `calendar_list` together with the `calendar_paths` derived from
  its `selected: true` entries.

  `calendar_paths` is what the CalDAV sync worker iterates over to decide
  which collections to fetch; `calendar_list` carries per-calendar metadata
  (name, type, selected). The two MUST move together — writing one
  without the other is the bug behind issue #50, where toggling a
  calendar off in the dashboard left it being synced because the worker
  never saw the change.

  Always use this rather than passing a bare `%{calendar_list: ...}` to
  `update_calendar_integration/2`.
  """
  @spec persist_calendar_list(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          [CalendarEntry.t()]
        ) ::
          {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()} | {:error, any()}
  def persist_calendar_list(integration, calendar_list) when is_list(calendar_list) do
    Management.update_calendar_integration(
      integration,
      calendar_list_attrs(calendar_list)
    )
  end

  @doc """
  Builds the `%{calendar_list: ..., calendar_paths: ...}` attribute pair
  to merge into a multi-field update (e.g. reconnection, which also
  rewrites credentials). For updates that only touch the selection, prefer
  `persist_calendar_list/2`.
  """
  @spec calendar_list_attrs([CalendarEntry.t()]) :: %{
          calendar_list: [CalendarEntry.t()],
          calendar_paths: [String.t()]
        }
  def calendar_list_attrs(calendar_list) when is_list(calendar_list) do
    %{calendar_list: calendar_list, calendar_paths: derive_selected_paths(calendar_list)}
  end

  @doc """
  Returns the paths of the calendars marked `selected: true`.

  Falls back to `id` when `path` is absent (CalDAV discovery emits only
  `id`).
  """
  @spec derive_selected_paths([CalendarEntry.t()]) :: [String.t()]
  def derive_selected_paths(calendar_list) when is_list(calendar_list) do
    for cal <- calendar_list,
        entry = cal |> CalendarEntry.normalize() |> CalendarEntry.with_defaults(),
        entry.selected,
        path = entry.path,
        is_binary(path),
        path != "",
        do: path
  end

  @doc """
  Returns the entries from a `calendar_list` whose `selected` flag is truthy,
  including read-only ones.

  Use this for conflict-checking visibility — a calendar the user cannot
  write to can still surface existing events. Returns `[]` for nil input so
  callers can treat absent and empty selections uniformly. See
  `writable_calendars/1` for the narrower booking/sync-target variant.
  """
  @spec selected_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  def selected_calendars(nil), do: []

  def selected_calendars(calendar_list) when is_list(calendar_list) do
    Enum.filter(calendar_list, & &1.selected)
  end

  @doc """
  Whether `entry`'s busy time removes slots from the booking page: it is
  selected and the owner has not set it to show only. A deselected calendar
  never blocks, whatever its `blocks_availability` says.
  """
  @spec blocking?(CalendarEntry.t()) :: boolean()
  def blocking?(%CalendarEntry{selected: selected, blocks_availability: blocks}),
    do: selected and blocks

  @doc """
  Returns the entries from a `calendar_list` that block availability (see
  `blocking?/1`), read-only ones included. `[]` for nil input.
  """
  @spec blocking_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  def blocking_calendars(nil), do: []

  def blocking_calendars(calendar_list) when is_list(calendar_list),
    do: calendar_list |> Enum.map(&CalendarEntry.normalize/1) |> Enum.filter(&blocking?/1)

  @doc """
  Returns the selected entries from a `calendar_list` that are also
  writable — the calendars available as booking/sync targets. Read-only
  calendars can still be selected for conflict-checking visibility (see
  `selected_calendars/1`) but can never be written to, so they are excluded
  here.
  """
  @spec writable_calendars([CalendarEntry.t()] | nil) :: [CalendarEntry.t()]
  def writable_calendars(calendar_list) do
    calendar_list
    |> selected_calendars()
    |> Enum.reject(& &1.read_only)
  end

  @doc """
  Restricts a list of integrations to those that can take a new event.

  An integration whose calendars are all read-only is not a possible target,
  and offering it is worse than leaving it out: the pickers make it look
  selectable, and the write then fails with `{:error, :read_only}`. A
  subscribed ICS feed is the clearest case — `Ics.Provider` returns a single
  synthetic entry flagged `read_only: true` precisely so it stays out of every
  booking-target picker.

  An integration with **no** calendar list is kept, unless its provider is
  read-only. An empty list means "not discovered yet", not "nothing writable":
  a CalDAV account before its first discovery, or a provider that exposes one
  implicit calendar, both belong in the list and are written to through the
  provider's own default. A read-only provider is dropped whatever its list
  says, so the rule does not depend on every subscription carrying its
  synthetic entry.
  """
  @spec writable_integrations([BookingEligibility.integration()]) ::
          [BookingEligibility.integration()]
  def writable_integrations(integrations) when is_list(integrations) do
    Enum.filter(integrations, &writable_target?/1)
  end

  # Whether `integration` can take a new event. See `writable_integrations/1`.
  @spec writable_target?(BookingEligibility.integration()) :: boolean()
  defp writable_target?(integration) do
    BookingEligibility.bookable?(integration) and has_writable_calendar?(integration)
  end

  defp has_writable_calendar?(%{calendar_list: list}) when is_list(list) and list != [],
    do: writable_calendars(list) != []

  defp has_writable_calendar?(_integration), do: true

  defp find_calendar_by_id(calendar_list, id) when is_list(calendar_list) do
    Enum.find(calendar_list, &(&1.id == id))
  end

  @doc """
  Finds the calendar entry whose `path` is a prefix of the given
  provider-side identifier (e.g. a CalDAV event href). Falls back to `id`
  when `path` is absent — legacy CalDAV integrations persisted `path: nil`.
  """
  @spec find_calendar_by_path([CalendarEntry.t()], String.t() | nil) :: CalendarEntry.t() | nil
  def find_calendar_by_path(calendar_list, path)
      when is_list(calendar_list) and is_binary(path) do
    Enum.find(calendar_list, fn entry ->
      prefix = entry.path || entry.id
      is_binary(prefix) and String.starts_with?(path, prefix)
    end)
  end

  def find_calendar_by_path(_calendar_list, _path), do: nil

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
    case selected_calendars(calendar_list) do
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
      {integration.id, integration_rule(integration, &selected_calendars/1)}
    end)
  end

  defp integration_rule(%{calendar_list: list}, _pick) when list in [nil, []], do: :all

  defp integration_rule(%{calendar_list: calendar_list}, pick),
    do: entries_rule(pick.(calendar_list))

  @doc """
  The `t:visibility_rule/0` matching cached rows from `entries`: `:none`
  for no entries.
  """
  @spec entries_rule([CalendarEntry.t()]) :: visibility_rule()
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
      find_calendar_by_path(calendar_list, event.provider_event_id)
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
end
