defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema do
  @moduledoc """
  Schema for cached calendar events fetched from external calendar providers.

  Events are keyed by (calendar_integration_id, uid) and reflect the state of
  the external calendar at the time of the last sync.

  That key carries an assumption worth stating, because nothing enforces it:
  each read path an integration performs must produce uids in its own
  namespace. Exchange is where it bites — one meeting is cached twice, once
  from the busy-time read under a synthesised uid and once from the item read
  under the real one, the two rows distinguished by the `role` column added in
  migration 20260819170109. A path that ever produced the same uid from both
  reads would collapse them into whichever role was written first, silently and
  unrecoverably, since `role` is held out of the upsert's replace list. Keep the
  namespaces disjoint by construction rather than by luck.

  Use `to_calendar_event/1` to convert a loaded record into the canonical
  `CalendarEvent` struct, and `from_calendar_event/1` to prepare a struct
  for database upsert.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.EventRole
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Reminder

  require Logger

  @timestamps_opts [type: :utc_datetime_usec]

  # Compile-time lookups from the string form of each atom-valued field's
  # value to its atom. Every calendar provider (regardless of runtime
  # enable/disable toggles) and the visibility/transparency/status
  # vocabularies each get their own table, so a value can only ever validate
  # against the field it belongs to: a `status` string does not accidentally
  # parse as a `provider`, and vice versa. Parsing through these tables keeps
  # the string entry point total: no `String.to_existing_atom/1` raise to
  # rescue, and no dependence on whether the atom happens to have been loaded
  # yet.
  @known_providers Map.new(
                     ProviderConfig.provider_constraint_list(),
                     &{&1, String.to_existing_atom(&1)}
                   )
  @known_visibilities Map.new([:public, :private, :confidential], &{Atom.to_string(&1), &1})
  @known_transparencies Map.new([:transparent, :opaque], &{Atom.to_string(&1), &1})
  @known_statuses Map.new(
                    [:confirmed, :tentative, :cancelled, :declined],
                    &{Atom.to_string(&1), &1}
                  )

  @type t :: %__MODULE__{
          id: integer() | nil,
          uid: String.t() | nil,
          calendar_integration_id: integer() | nil,
          provider: String.t() | nil,
          provider_calendar_id: String.t() | nil,
          provider_event_id: String.t() | nil,
          role: String.t(),
          summary: String.t() | nil,
          description: String.t() | nil,
          location: String.t() | nil,
          visibility: String.t() | nil,
          colour: String.t() | nil,
          all_day: boolean(),
          start_date: Date.t() | nil,
          end_date: Date.t() | nil,
          start_at: DateTime.t() | nil,
          end_at: DateTime.t() | nil,
          timezone: String.t() | nil,
          transparency: String.t(),
          status: String.t(),
          organiser: map() | nil,
          attendees: [map()],
          recurrence_rule: String.t() | nil,
          recurrence_exceptions: [Date.t()],
          recurring_event_id: String.t() | nil,
          attachments: [map()],
          links: [map()],
          reminders: [map()],
          etag: String.t() | nil,
          synced_at: DateTime.t() | nil,
          provider_updated_at: DateTime.t() | nil,
          provider_metadata: map(),
          raw_ical: String.t() | nil,
          sync_state: String.t(),
          sync_attempts: integer(),
          sync_last_attempt_at: DateTime.t() | nil,
          sync_last_error: String.t() | nil,
          created_by_tymeslot: boolean(),
          ical_sequence: integer(),
          last_notified_state: map(),
          video_link: String.t() | nil,
          video_integration_id: integer() | nil,
          video_integration:
            Tymeslot.Integrations.Video.VideoIntegrationSchema.t()
            | Ecto.Association.NotLoaded.t()
            | nil,
          calendar_integration:
            CalendarIntegrationSchema.t()
            | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "provider_calendar_events" do
    field :uid, :string
    field :provider, :string
    field :provider_calendar_id, :string
    field :provider_event_id, :string

    # Which read path owns the row, and therefore which reads may return it.
    # Insert-time identity: deliberately absent from
    # `ProviderCalendarEventQueries.replace_fields/0` and from the changeset's
    # castable fields, so no partial update can re-file a row. See migration
    # 20260819170109 for how it composes with `transparency` and `status`.
    field :role, :string, default: EventRole.both()

    # Content
    field :summary, :string
    field :description, :string
    field :location, :string
    field :visibility, :string
    field :colour, :string

    # Timing
    field :all_day, :boolean, default: false
    field :start_date, :date
    field :end_date, :date
    field :start_at, :utc_datetime_usec
    field :end_at, :utc_datetime_usec
    field :timezone, :string

    # Scheduling
    field :transparency, :string, default: "opaque"
    field :status, :string, default: "confirmed"

    # People
    field :organiser, :map
    field :attendees, {:array, :map}, default: []

    # Recurrence
    field :recurrence_rule, :string
    field :recurrence_exceptions, {:array, :date}, default: []
    field :recurring_event_id, :string

    # Attachments & links
    field :attachments, {:array, :map}, default: []
    field :links, {:array, :map}, default: []

    # Reminders
    field :reminders, {:array, :map}, default: []

    # Sync
    field :etag, :string
    field :synced_at, :utc_datetime_usec
    field :provider_updated_at, :utc_datetime_usec
    field :provider_metadata, :map, default: %{}
    field :raw_ical, :string
    field :created_by_tymeslot, :boolean, default: false

    # Offline write queue bookkeeping. See
    # AddSyncStateToProviderCalendarEvents migration for semantics.
    field :sync_state, :string, default: "synced"
    field :sync_attempts, :integer, default: 0
    field :sync_last_attempt_at, :utc_datetime_usec
    field :sync_last_error, :string

    # Notification tracking
    field :ical_sequence, :integer, default: 0
    field :last_notified_state, :map, default: %{}

    # Video conferencing
    field :video_link, :string

    belongs_to :calendar_integration, CalendarIntegrationSchema

    belongs_to :video_integration,
               Tymeslot.Integrations.Video.VideoIntegrationSchema,
               type: :id

    timestamps(type: :utc_datetime_usec)
  end

  @required_fields [:uid, :calendar_integration_id, :provider, :all_day, :synced_at]

  @optional_fields [
    :provider_calendar_id,
    :provider_event_id,
    :summary,
    :description,
    :location,
    :visibility,
    :colour,
    :start_date,
    :end_date,
    :start_at,
    :end_at,
    :timezone,
    :transparency,
    :status,
    :organiser,
    :attendees,
    :recurrence_rule,
    :recurrence_exceptions,
    :recurring_event_id,
    :attachments,
    :links,
    :reminders,
    :etag,
    :provider_updated_at,
    :provider_metadata,
    :raw_ical,
    :sync_state,
    :sync_attempts,
    :sync_last_attempt_at,
    :sync_last_error,
    :created_by_tymeslot,
    :ical_sequence,
    :last_notified_state,
    :video_link,
    :video_integration_id
  ]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(cache_event, attrs) do
    cache_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:calendar_integration_id)
    |> unique_constraint([:calendar_integration_id, :uid])
  end

  @doc """
  Converts a loaded schema record into a canonical `CalendarEvent` struct.

  Atom-valued fields (provider, transparency, status, visibility) are converted
  from their database string representation.
  """
  @spec to_calendar_event(t()) :: CalendarEvent.t()
  def to_calendar_event(%__MODULE__{} = record) do
    %CalendarEvent{
      uid: record.uid,
      calendar_integration_id: record.calendar_integration_id,
      provider: safe_to_atom(record.provider, @known_providers),
      provider_calendar_id: record.provider_calendar_id,
      provider_event_id: record.provider_event_id,
      recurring_event_id: record.recurring_event_id,
      summary: record.summary,
      description: record.description,
      location: record.location,
      visibility: safe_to_atom(record.visibility, @known_visibilities),
      colour: record.colour,
      all_day: record.all_day,
      start_date: record.start_date,
      end_date: record.end_date,
      start_at: record.start_at,
      end_at: record.end_at,
      timezone: record.timezone,
      transparency: safe_to_atom(record.transparency, @known_transparencies) || :opaque,
      status: safe_to_atom(record.status, @known_statuses) || :confirmed,
      organiser: record.organiser,
      attendees: record.attendees || [],
      recurrence_rule: record.recurrence_rule,
      recurrence_exceptions: record.recurrence_exceptions || [],
      attachments: record.attachments || [],
      links: record.links || [],
      reminders: normalise_reminders(record.reminders),
      etag: record.etag,
      synced_at: record.synced_at,
      provider_updated_at: record.provider_updated_at,
      provider_metadata: record.provider_metadata || %{},
      raw_ical: record.raw_ical,
      created_by_tymeslot: record.created_by_tymeslot || false
    }
  end

  @doc """
  Converts a `CalendarEvent` struct into a map suitable for database upsert.

  Atom-valued fields are converted to strings for storage.
  """
  @spec from_calendar_event(CalendarEvent.t()) :: map()
  def from_calendar_event(%CalendarEvent{} = event) do
    %{
      uid: event.uid,
      calendar_integration_id: event.calendar_integration_id,
      provider: safe_to_string(event.provider),
      provider_calendar_id: event.provider_calendar_id,
      provider_event_id: event.provider_event_id,
      recurring_event_id: event.recurring_event_id,
      summary: event.summary,
      description: event.description,
      location: event.location,
      visibility: safe_to_string(event.visibility),
      colour: event.colour,
      all_day: event.all_day,
      start_date: event.start_date,
      end_date: event.end_date,
      start_at: ensure_usec(event.start_at),
      end_at: ensure_usec(event.end_at),
      timezone: event.timezone,
      transparency: safe_to_string(event.transparency),
      status: safe_to_string(event.status),
      organiser: event.organiser,
      attendees: event.attendees,
      recurrence_rule: event.recurrence_rule,
      recurrence_exceptions: event.recurrence_exceptions,
      attachments: event.attachments,
      links: event.links,
      reminders: event.reminders,
      etag: event.etag,
      synced_at: ensure_usec(event.synced_at),
      provider_updated_at: ensure_usec(event.provider_updated_at),
      provider_metadata: event.provider_metadata,
      raw_ical: event.raw_ical,
      created_by_tymeslot: event.created_by_tymeslot
    }
  end

  defp ensure_usec(nil), do: nil

  defp ensure_usec(%DateTime{microsecond: {_us, 6}} = dt), do: dt

  defp ensure_usec(%DateTime{} = dt) do
    {us, _precision} = dt.microsecond
    %{dt | microsecond: {us, 6}}
  end

  # Reminders are stored in a JSONB column, so even atom-keyed maps written by
  # the dashboard come back string-keyed. Normalise to the canonical
  # `%{method: :popup | :email | :sms, minutes_before: integer}` shape that the
  # UI and the provider mappers expect.
  defp normalise_reminders(nil), do: []

  defp normalise_reminders(reminders) when is_list(reminders),
    do: Enum.map(reminders, &Reminder.normalise/1)

  defp normalise_reminders(_other), do: []

  defp safe_to_atom(nil, _known), do: nil
  defp safe_to_atom(value, _known) when is_atom(value), do: value

  # Provider, visibility, transparency, and status are each stored as strings
  # drawn from their own fixed vocabulary. A value absent from the relevant
  # table means the stored data has drifted from what this application knows
  # about (or belongs to a different field entirely), so record it before
  # falling back.
  defp safe_to_atom(value, known) when is_binary(value) do
    case Map.fetch(known, value) do
      {:ok, atom} ->
        atom

      :error ->
        Logger.debug("Stored calendar event value is not a known atom", value: value)

        nil
    end
  end

  defp safe_to_string(nil), do: nil
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
end
