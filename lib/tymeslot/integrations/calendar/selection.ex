defmodule Tymeslot.Integrations.Calendar.Selection do
  @moduledoc """
  Business logic for calendar discovery/selection merging and preparing params
  for persistence.
  """

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.CalendarManagement
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
  Discover calendars for the given integration and merge with existing selection
  state (integration.calendar_list), returning a unified list where each item
  includes a boolean "selected" field.
  """
  @spec discover_with_selection(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()) ::
          {:ok, list()} | {:error, term()}
  def discover_with_selection(integration) do
    case Calendar.discover_calendars_for_integration(integration) do
      {:ok, calendars} ->
        {:ok, unify_discovered_with_existing(calendars, integration.calendar_list)}

      error ->
        error
    end
  end

  @doc """
  Merge discovered calendars with an existing list of selections.
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
      selected = lookup_selection(existing_map, [entry.path, entry.id])
      %{entry | selected: selected}
    end)
  end

  defp build_existing_selection_map(existing) do
    Enum.reduce(existing, %{}, fn cal, acc ->
      entry = CalendarEntry.normalize(cal)

      acc
      |> maybe_put(entry.path, entry.selected)
      |> maybe_put(entry.id, entry.selected)
      |> maybe_put_decoded(entry.path, entry.selected)
      |> maybe_put_decoded(entry.id, entry.selected)
    end)
  end

  defp path_in_selected?(path, selected_paths) do
    Enum.any?(selected_paths, &UriUtils.uri_safe_match?(path, &1))
  end

  # Looks up a selection boolean for a calendar identified by any of the given
  # keys (tried in order). Treats false and true as distinct — unlike `||`, this
  # returns false immediately when a key is present with that value rather than
  # continuing to the next candidate.
  defp lookup_selection(existing_map, keys) do
    keys
    |> Enum.flat_map(fn
      nil -> []
      key -> [key, UriUtils.safe_decode(key)]
    end)
    |> Enum.find_value(false, fn key ->
      if Map.has_key?(existing_map, key), do: Map.fetch!(existing_map, key)
    end)
  end

  defp maybe_put(acc, nil, _val), do: acc
  defp maybe_put(acc, key, val), do: Map.put(acc, key, val)

  defp maybe_put_decoded(acc, nil, _val), do: acc

  defp maybe_put_decoded(acc, key, val) do
    decoded = UriUtils.safe_decode(key)
    if decoded == key, do: acc, else: Map.put(acc, decoded, val)
  end

  @doc """
  Update calendar selection for an integration.
  """
  @spec update_calendar_selection(
          Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t(),
          %{String.t() => term()}
        ) :: {:ok, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()} | {:error, any()}
  def update_calendar_selection(integration, params) do
    selected_calendar_ids = params["selected_calendars"] || []

    calendar_list =
      Enum.map(integration.calendar_list || [], fn cal ->
        entry = cal |> CalendarEntry.normalize() |> CalendarEntry.with_defaults()
        is_selected = Enum.any?(selected_calendar_ids, &UriUtils.uri_safe_match?(entry.id, &1))
        %{entry | selected: is_selected}
      end)

    persist_calendar_list(integration, calendar_list)
  end

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
    CalendarManagement.update_calendar_integration(
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
  Finds the calendar entry with the given id.
  """
  @spec find_calendar_by_id([CalendarEntry.t()], String.t() | nil) :: CalendarEntry.t() | nil
  def find_calendar_by_id(calendar_list, id) when is_list(calendar_list) do
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
    selected = selected_calendars(calendar_list)

    cond do
      selected == [] -> false
      caldav_event?(event) -> matches_selected_calendar_path?(event, selected)
      true -> matches_selected_calendar_id?(event, selected)
    end
  end

  defp caldav_event?(%{provider_event_id: peid}) when is_binary(peid),
    do: String.starts_with?(peid, "/")

  defp caldav_event?(_event), do: false

  defp matches_selected_calendar_id?(%{provider_calendar_id: pcid}, selected)
       when is_binary(pcid) do
    not is_nil(find_calendar_by_id(selected, pcid))
  end

  defp matches_selected_calendar_id?(_event, _selected), do: false

  defp matches_selected_calendar_path?(%{provider_event_id: peid}, selected)
       when is_binary(peid) do
    not is_nil(find_calendar_by_path(selected, peid))
  end
end
