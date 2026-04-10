defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema do
  @moduledoc """
  Schema for cached calendar events fetched from external calendar providers.

  Events are keyed by (calendar_integration_id, uid) and reflect the state of
  the external calendar at the time of the last sync.

  Use `to_calendar_event/1` to convert a loaded record into the canonical
  `CalendarEvent` struct, and `from_calendar_event/1` to prepare a struct
  for database upsert.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          id: integer() | nil,
          uid: String.t() | nil,
          calendar_integration_id: integer() | nil,
          provider: String.t() | nil,
          provider_calendar_id: String.t() | nil,
          provider_event_id: String.t() | nil,
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
          created_by_tymeslot: boolean(),
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
    field :created_by_tymeslot, :boolean, default: false

    belongs_to :calendar_integration, CalendarIntegrationSchema

    timestamps()
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
    :created_by_tymeslot
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
      provider: safe_to_atom(record.provider),
      provider_calendar_id: record.provider_calendar_id,
      provider_event_id: record.provider_event_id,
      recurring_event_id: record.recurring_event_id,
      summary: record.summary,
      description: record.description,
      location: record.location,
      visibility: safe_to_atom(record.visibility),
      colour: record.colour,
      all_day: record.all_day,
      start_date: record.start_date,
      end_date: record.end_date,
      start_at: record.start_at,
      end_at: record.end_at,
      timezone: record.timezone,
      transparency: safe_to_atom(record.transparency) || :opaque,
      status: safe_to_atom(record.status) || :confirmed,
      organiser: record.organiser,
      attendees: record.attendees || [],
      recurrence_rule: record.recurrence_rule,
      recurrence_exceptions: record.recurrence_exceptions || [],
      attachments: record.attachments || [],
      links: record.links || [],
      reminders: record.reminders || [],
      etag: record.etag,
      synced_at: record.synced_at,
      provider_updated_at: record.provider_updated_at,
      provider_metadata: record.provider_metadata || %{},
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
      created_by_tymeslot: event.created_by_tymeslot
    }
  end

  defp ensure_usec(nil), do: nil

  defp ensure_usec(%DateTime{microsecond: {_us, 6}} = dt), do: dt

  defp ensure_usec(%DateTime{} = dt) do
    {us, _precision} = dt.microsecond
    %{dt | microsecond: {us, 6}}
  end

  defp safe_to_atom(nil), do: nil
  defp safe_to_atom(value) when is_atom(value), do: value

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp safe_to_string(nil), do: nil
  defp safe_to_string(value) when is_binary(value), do: value
  defp safe_to_string(value) when is_atom(value), do: Atom.to_string(value)
end
