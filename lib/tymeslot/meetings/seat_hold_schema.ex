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

  `create_changeset/2` applies the same contact rules as
  `ParticipantSchema.creation_changeset/2` (`BookerContact`), so a hold that
  saves can always convert.

  Status transitions are conditional updates in
  `Tymeslot.Meetings.SeatHoldQueries` (`WHERE status = 'held'` for a
  release), never changesets of a loaded struct, so two racing callers
  cannot both move one hold. The release reason `:abandoned` is allowed by
  the `seat_holds_released_reason_must_be_known` check but no code writes it.

  The `booking_payments_seat_hold_id_fkey` check is deferred, so it only runs
  at commit and never in the test sandbox (which never commits). A test that
  needs it runs
  `Repo.query!("SET CONSTRAINTS booking_payments_seat_hold_id_fkey IMMEDIATE")`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Meetings.BookerContact
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

  @required ~w(meeting_id start_time seats expires_at)a

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = hold \\ %__MODULE__{}, attrs) do
    hold
    |> cast(attrs, @castable)
    |> validate_required(@required)
    |> BookerContact.validate()
    |> validate_number(:seats, greater_than_or_equal_to: 1)
    |> foreign_key_constraint(:meeting_id)
    |> unique_constraint(:email, name: :seat_holds_live_email_index)
    |> check_constraint(:seats, name: :seat_holds_seats_positive)
    |> check_constraint(:status, name: :seat_holds_status_must_be_known)
    |> check_constraint(:released_reason, name: :seat_holds_released_reason_must_be_known)
    |> check_constraint(:released_reason, name: :seat_holds_released_has_reason)
  end

  @doc """
  Whether the insert failed on `seat_holds_live_email_index`: the email
  already holds seats on the meeting.
  """
  @spec duplicate_hold?(Ecto.Changeset.t()) :: boolean()
  def duplicate_hold?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      to_string(opts[:constraint_name] || "") == "seat_holds_live_email_index"
    end)
  end

  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @spec release_reasons() :: [release_reason()]
  def release_reasons, do: @release_reasons
end
