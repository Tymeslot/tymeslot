defmodule Tymeslot.Integrations.Calendar.CalendarEventCacheSchema do
  @moduledoc """
  Schema for cached calendar events fetched from external calendar providers.

  Events are keyed by (calendar_integration_id, uid) and reflect the state of
  the external calendar at the time of the last sync.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @timestamps_opts [type: :utc_datetime]

  @type t :: %__MODULE__{
          id: integer() | nil,
          uid: String.t() | nil,
          calendar_integration_id: integer() | nil,
          calendar_path: String.t() | nil,
          provider_event_id: String.t() | nil,
          title: String.t() | nil,
          start_at: DateTime.t() | nil,
          end_at: DateTime.t() | nil,
          all_day: boolean(),
          location: String.t() | nil,
          description: String.t() | nil,
          attendees: [map()],
          recurrence_rule: String.t() | nil,
          recurring_event_id: String.t() | nil,
          status: String.t() | nil,
          raw_data: map() | nil,
          etag: String.t() | nil,
          synced_at: DateTime.t() | nil,
          calendar_integration:
            Tymeslot.Integrations.Calendar.CalendarIntegrationSchema.t()
            | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "calendar_events" do
    field(:uid, :string)
    field(:calendar_path, :string)
    field(:provider_event_id, :string)
    field(:title, :string)
    field(:start_at, :utc_datetime)
    field(:end_at, :utc_datetime)
    field(:all_day, :boolean, default: false)
    field(:location, :string)
    field(:description, :string)
    field(:attendees, {:array, :map}, default: [])
    field(:recurrence_rule, :string)
    field(:recurring_event_id, :string)
    field(:status, :string)
    field(:raw_data, :map)
    field(:etag, :string)
    field(:synced_at, :utc_datetime)

    belongs_to(:calendar_integration, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema)

    timestamps()
  end

  @required_fields [:uid, :calendar_integration_id, :start_at, :end_at]

  @optional_fields [
    :calendar_path,
    :provider_event_id,
    :title,
    :all_day,
    :location,
    :description,
    :attendees,
    :recurrence_rule,
    :recurring_event_id,
    :status,
    :raw_data,
    :etag,
    :synced_at
  ]

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(calendar_event, attrs) do
    calendar_event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:calendar_integration_id)
    |> unique_constraint([:calendar_integration_id, :uid])
  end
end
