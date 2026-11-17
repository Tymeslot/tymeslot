defmodule Tymeslot.Meetings.SeatHoldSchema do
  @moduledoc """
  An unpaid booker's claim on seats of a paid group meeting.

  A hold is never a `meeting_participants` row: it counts against the
  meeting's capacity (guests included) while its Stripe Checkout session lives
  (30 minutes), is invisible everywhere else, and is converted into an
  ordinary participant when the payment completes. It snapshots the
  participant fields so that participant can be built later.

  `custom_field_answers` is personal data and must not be logged.
  `guests` is a list of `%{"name" => nil | String.t(), "email" => String.t()}`.
  A converted hold keeps no database-enforced link to its participant
  (`participant_id` is nilified when the participant is deleted).
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses [:held, :converted, :released]
  @release_reasons [:expired, :failed, :abandoned, :meeting_cancelled]

  @type status :: :held | :converted | :released
  @type release_reason :: :expired | :failed | :abandoned | :meeting_cancelled

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          meeting_id: Ecto.UUID.t() | nil,
          meeting_type_id: integer() | nil,
          participant_id: Ecto.UUID.t() | nil,
          start_time: DateTime.t() | nil,
          seats: integer() | nil,
          status: status(),
          released_reason: release_reason() | nil,
          expires_at: DateTime.t() | nil,
          name: String.t() | nil,
          email: String.t() | nil,
          phone: String.t() | nil,
          company: String.t() | nil,
          message: String.t() | nil,
          timezone: String.t() | nil,
          locale: String.t(),
          custom_field_answers: map(),
          guests: [map()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "seat_holds" do
    field :start_time, :utc_datetime
    field :seats, :integer
    field :status, Ecto.Enum, values: @statuses, default: :held
    field :released_reason, Ecto.Enum, values: @release_reasons
    field :expires_at, :utc_datetime

    field :name, :string
    field :email, :string
    field :phone, :string
    field :company, :string
    field :message, :string
    field :timezone, :string
    field :locale, :string, default: "en"
    field :custom_field_answers, :map, default: %{}
    field :guests, {:array, :map}, default: []

    belongs_to :meeting, MeetingSchema
    belongs_to :meeting_type, MeetingTypeSchema, type: :id
    belongs_to :participant, ParticipantSchema

    timestamps(type: :utc_datetime)
  end

  @castable ~w(
    meeting_id meeting_type_id start_time seats expires_at guests
    name email phone company message timezone locale custom_field_answers
  )a

  @required ~w(meeting_id start_time seats expires_at name email)a

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = hold \\ %__MODULE__{}, attrs) do
    hold
    |> cast(attrs, @castable)
    |> validate_required(@required)
    |> validate_number(:seats, greater_than_or_equal_to: 1)
    |> unique_constraint(:email, name: :seat_holds_live_email_index)
    |> check_constraint(:seats, name: :seat_holds_seats_positive)
    |> check_constraint(:status, name: :seat_holds_status_must_be_known)
    |> check_constraint(:released_reason, name: :seat_holds_released_reason_must_be_known)
    |> check_constraint(:released_reason, name: :seat_holds_released_has_reason)
  end

  @spec release_changeset(t(), release_reason()) :: Ecto.Changeset.t()
  def release_changeset(%__MODULE__{} = hold, reason) do
    hold
    |> change(status: :released, released_reason: reason)
    |> ensure_held(hold)
  end

  @spec convert_changeset(t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def convert_changeset(%__MODULE__{} = hold, participant_id) do
    hold
    |> change(status: :converted, participant_id: participant_id)
    |> ensure_held(hold)
  end

  defp ensure_held(changeset, %__MODULE__{status: :held}), do: changeset

  defp ensure_held(changeset, %__MODULE__{}),
    do: add_error(changeset, :status, "is not held")

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec release_reasons() :: [release_reason()]
  def release_reasons, do: @release_reasons
end
