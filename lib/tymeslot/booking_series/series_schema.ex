defmodule Tymeslot.BookingSeries.SeriesSchema do
  @moduledoc """
  Ecto schema for a booking series: the sessions a booker reserved in one flow.

  Every occurrence is an ordinary `meetings` row (or a `meeting_participants`
  row on a group type) carrying `series_id` and `series_position`. A
  `recurring` series repeats at one time on a fixed rhythm (`frequency` and
  `interval`); a `flexible` one has its sessions picked at different times and
  needs no rule. `uid` is the bearer for the attendee's series page.

  `first_start_at` is when the first session started as booked. It stays
  put as sessions move, so the year a later session may be moved within
  (`Tymeslot.BookingSeries.window_until/1`) cannot creep along with them.

  `cancelled_at` says no session of the series is left to come: the rest
  were cancelled, whether all at once or one at a time, or its request was
  released. It does not mean every session was cancelled; sessions that
  already took place keep their own status
  (`Tymeslot.BookingSeries.Cancel`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema

  @type t :: %__MODULE__{
          id: binary() | nil,
          uid: Ecto.UUID.t() | nil,
          organizer_user_id: integer() | nil,
          meeting_type_id: integer() | nil,
          mode: :recurring | :flexible | nil,
          frequency: :daily | :weekly | :monthly | nil,
          interval: pos_integer() | nil,
          occurrences_count: pos_integer() | nil,
          attendee_name: String.t() | nil,
          attendee_email: String.t() | nil,
          attendee_timezone: String.t() | nil,
          attendee_locale: String.t() | nil,
          unit_price_cents: non_neg_integer() | nil,
          first_start_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          invitee_data_erased_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "booking_series" do
    field :uid, Ecto.UUID, autogenerate: true
    field :mode, Ecto.Enum, values: [:recurring, :flexible]
    field :frequency, Ecto.Enum, values: [:daily, :weekly, :monthly]
    field :interval, :integer
    field :occurrences_count, :integer
    field :attendee_name, :string
    field :attendee_email, :string
    field :attendee_timezone, :string
    field :attendee_locale, :string
    field :unit_price_cents, :integer
    field :first_start_at, :utc_datetime_usec
    field :cancelled_at, :utc_datetime_usec
    field :invitee_data_erased_at, :utc_datetime_usec

    belongs_to :organizer_user, Tymeslot.Auth.UserSchema,
      foreign_key: :organizer_user_id,
      type: :id

    belongs_to :meeting_type, Tymeslot.MeetingTypes.MeetingTypeSchema,
      foreign_key: :meeting_type_id,
      type: :id

    has_many :meetings, MeetingSchema, foreign_key: :series_id
    has_many :participants, ParticipantSchema, foreign_key: :series_id

    timestamps(type: :utc_datetime_usec)
  end

  @castable [
    :uid,
    :organizer_user_id,
    :meeting_type_id,
    :mode,
    :frequency,
    :interval,
    :occurrences_count,
    :attendee_name,
    :attendee_email,
    :attendee_timezone,
    :attendee_locale,
    :unit_price_cents,
    :first_start_at
  ]

  @doc "Changeset for creating a series. `cancelled_at` and erasure are never cast."
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(series \\ %__MODULE__{}, attrs) do
    series
    |> cast(attrs, @castable)
    |> validate_required([:mode, :occurrences_count, :attendee_name, :attendee_email])
    |> unique_constraint(:uid)
    |> check_constraint(:mode, name: :booking_series_mode_check)
    |> check_constraint(:frequency, name: :booking_series_rule_check)
    |> check_constraint(:occurrences_count, name: :booking_series_count_check)
  end

  @doc "Marks the series closed: no session of it is left to come."
  @spec cancel_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def cancel_changeset(%__MODULE__{} = series, %DateTime{} = cancelled_at) do
    change(series, cancelled_at: cancelled_at)
  end
end
