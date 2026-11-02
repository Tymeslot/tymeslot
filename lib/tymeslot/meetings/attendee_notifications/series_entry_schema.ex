defmodule Tymeslot.Meetings.AttendeeNotifications.SeriesEntrySchema do
  @moduledoc """
  An entry in a guest's calendar that an attendee email about an occurrence
  of a recurring series put there (`Tymeslot.Meetings.AttendeeNotifications.SeriesEntries`).

  `series_address` is how the provider addresses the series as a whole
  (`master:<id>` or `resource:<href>`, from
  `Tymeslot.CalendarGrid.Occurrence.series_address/1`), `entry_uid` the UID
  the guest holds the entry under, and the timing and `sent_sequence` what
  it was last sent at: `start_at`/`end_at` for a timed entry,
  `start_date`/`end_date` (end exclusive) for an all-day one.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          calendar_integration_id: integer() | nil,
          series_address: String.t() | nil,
          entry_uid: String.t() | nil,
          start_at: DateTime.t() | nil,
          end_at: DateTime.t() | nil,
          start_date: Date.t() | nil,
          end_date: Date.t() | nil,
          sent_sequence: non_neg_integer()
        }

  schema "attendee_series_entries" do
    field(:series_address, :string)
    field(:entry_uid, :string)
    field(:start_at, :utc_datetime_usec)
    field(:end_at, :utc_datetime_usec)
    field(:start_date, :date)
    field(:end_date, :date)
    field(:sent_sequence, :integer, default: 0)

    belongs_to(:calendar_integration, CalendarIntegrationSchema)

    timestamps(type: :utc_datetime)
  end

  @fields [
    :calendar_integration_id,
    :series_address,
    :entry_uid,
    :start_at,
    :end_at,
    :start_date,
    :end_date,
    :sent_sequence
  ]

  @doc "The columns a later email about the same entry replaces."
  @spec replaced_fields() :: [atom()]
  def replaced_fields, do: [:start_at, :end_at, :start_date, :end_date, :sent_sequence]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields)
    |> validate_required([:calendar_integration_id, :series_address, :entry_uid, :sent_sequence])
    |> validate_number(:sent_sequence, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:calendar_integration_id)
    |> unique_constraint([:calendar_integration_id, :series_address, :entry_uid],
      name: :attendee_series_entries_entry_index
    )
  end
end
