defmodule Tymeslot.Integrations.Calendar.CalendarEntry do
  @moduledoc """
  Custom `Ecto.Type` for a single entry in `CalendarIntegrationSchema.calendar_list`.

  Calendar payloads reach the app in two shapes: string-keyed once they have
  round-tripped through the `calendar_list` JSONB column, atom-keyed straight
  from provider discovery (Google, Outlook, CalDAV/XML). Rather than every
  context, worker, and view defending for both key types at every read, this
  type normalises the shape once, at the schema boundary — `cast/1` accepts
  either shape (and a raw discovery map's `href` as a synonym for `path`),
  `load/1` casts what Postgres returns, `dump/1` writes canonical string keys
  back. Everything downstream reads a plain struct field.

  `normalize/1` is the same normalisation exposed for callers that need to
  reconcile a calendar map (e.g. fresh discovery output) before persistence
  has had a chance to run it through `cast/1` — mirrors the reference pattern
  in `Tymeslot.Integrations.Calendar.CalDAV.QueueWiring.normalize_event_data/1`.

  ## Fields

    * `:id` — provider identifier
    * `:path` — CalDAV collection path; falls back to the discovery `href`
      key, since CalDAV XML discovery emits only `href`. Absent for
      Google/Outlook, which identify calendars by `:id` alone.
    * `:name` — display name
    * `:type` — CalDAV resource type, defaults to `"calendar"`
    * `:selected` — whether the user has enabled this calendar for conflict
      checking/sync, defaults to `false`
    * `:read_only` — whether the provider reports this calendar as
      unwritable, defaults to `false`
    * `:primary` — whether the provider marks this as the account's default
      calendar, defaults to `false`
    * `:color` — provider display colour (Google `backgroundColor`, Outlook
      `color`, CalDAV `calendar-color`), when supplied
    * `:raw` — internal passthrough for keys `cast/1` doesn't recognise
      (e.g. Google's `description`/`access_role`, Outlook's
      `can_edit`/`owner`, discovery's `metadata`/`provider`), so a
      round-trip through this type never silently drops data it doesn't
      understand. Not part of the public reading surface: callers must not
      read or rely on this field, only the eight named ones above.

  `:primary` and `:color` were added after `:id`/`:path`/`:name`/`:type`/
  `:selected`/`:read_only`. No writer rewrote already-persisted
  `calendar_list` rows when these fields were introduced, so any integration
  connected before this change loads with `primary: false` and `color: nil`
  regardless of the provider's actual data, until its calendar list is next
  rediscovered (e.g. via a manual refresh). Callers that rely on `:primary`
  or `:color` must treat `false`/`nil` as "unknown", not as a confirmed
  negative, for calendars that predate this field.
  """

  use Ecto.Type

  @known_keys ~w(id path href name type selected read_only primary color)

  @type t :: %__MODULE__{
          id: String.t() | nil,
          path: String.t() | nil,
          name: String.t() | nil,
          type: String.t() | nil,
          selected: boolean(),
          read_only: boolean(),
          primary: boolean(),
          color: String.t() | nil,
          raw: map()
        }

  defstruct id: nil,
            path: nil,
            name: nil,
            type: "calendar",
            selected: false,
            read_only: false,
            primary: false,
            color: nil,
            raw: %{}

  @impl Ecto.Type
  def type, do: :map

  @impl Ecto.Type
  def cast(%__MODULE__{} = entry), do: {:ok, entry}
  def cast(%_struct{}), do: :error

  def cast(map) when is_map(map) do
    {:ok,
     %__MODULE__{
       id: fetch(map, :id),
       path: fetch(map, :path) || fetch(map, :href),
       name: fetch(map, :name),
       type: fetch(map, :type) || "calendar",
       selected: fetch(map, :selected) || false,
       read_only: fetch(map, :read_only) || false,
       primary: fetch(map, :primary) || false,
       color: fetch(map, :color),
       raw: extract_raw(map)
     }}
  end

  def cast(_other), do: :error

  @impl Ecto.Type
  def load(map) when is_map(map), do: cast(map)
  def load(_other), do: :error

  @impl Ecto.Type
  def dump(%__MODULE__{} = entry) do
    {:ok,
     Map.merge(entry.raw, %{
       "id" => entry.id,
       "path" => entry.path,
       "name" => entry.name,
       "type" => entry.type,
       "selected" => entry.selected,
       "read_only" => entry.read_only,
       "primary" => entry.primary,
       "color" => entry.color
     })}
  end

  def dump(map) when is_map(map) do
    case cast(map) do
      {:ok, entry} -> dump(entry)
      :error -> :error
    end
  end

  def dump(_other), do: :error

  @doc """
  Normalises a raw calendar map (fresh from provider discovery, atom-keyed)
  or a persisted entry (already a `#{inspect(__MODULE__)}`) into the struct.

  Used outside the Ecto cast/load path — e.g. business logic that reconciles
  discovery output before it has been persisted — so callers get the same
  single normalised shape `cast/1` produces at the schema boundary.
  """
  @spec normalize(t() | map()) :: t()
  def normalize(%__MODULE__{} = entry), do: entry

  def normalize(%_struct{} = other) do
    raise ArgumentError,
          "#{inspect(__MODULE__)}.normalize/1 expects a #{inspect(__MODULE__)} or a plain map, " <>
            "got: #{inspect(other)}"
  end

  def normalize(map) when is_map(map) do
    {:ok, entry} = cast(map)
    entry
  end

  @doc """
  Fills the fallbacks callers repeatedly re-derive by hand: `path` falls
  back to `id` (CalDAV discovery emits only `id`), `id` falls back to the
  resulting `path`, and a missing `name` becomes `"Calendar"`. Idempotent —
  safe to call on an entry that already has these fields set.
  """
  @spec with_defaults(t()) :: t()
  def with_defaults(%__MODULE__{} = entry) do
    path = entry.path || entry.id
    %{entry | path: path, id: entry.id || path, name: entry.name || "Calendar"}
  end

  defp fetch(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  # Collects whatever `cast/1` didn't recognise, keyed by string so it merges
  # cleanly under the canonical string keys `dump/1` writes.
  defp extract_raw(map) do
    for {key, value} <- map,
        key_string = key_string(key),
        not is_nil(key_string) and key_string not in @known_keys,
        into: %{} do
      {key_string, value}
    end
  end

  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key) when is_binary(key), do: key
  defp key_string(_key), do: nil
end
