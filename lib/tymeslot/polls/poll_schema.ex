defmodule Tymeslot.Polls.PollSchema do
  @moduledoc "A meeting poll: proposed candidate slots that invitees vote on."

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Polls.{PollParticipantSchema, PollTimeSlotSchema}
  alias Tymeslot.Utils.UnguessableToken

  @max_slots 40
  @max_participants 40

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "polls" do
    field(:title, :string)
    field(:description, :string)
    field(:duration_minutes, :integer)
    field(:token, :string)
    field(:status, Ecto.Enum, values: [:open, :confirmed, :cancelled], default: :open)
    field(:deadline_at, :utc_datetime)
    field(:timezone, :string)
    field(:confirmed_at, :utc_datetime)

    belongs_to(:user, UserSchema, type: :id)
    belongs_to(:meeting_type, MeetingTypeSchema, type: :id)
    belongs_to(:confirmed_meeting, MeetingSchema, type: :binary_id)

    has_many(:time_slots, PollTimeSlotSchema,
      foreign_key: :poll_id,
      preload_order: [asc: :position]
    )

    has_many(:participants, PollParticipantSchema,
      foreign_key: :poll_id,
      preload_order: [asc: :inserted_at]
    )

    timestamps(type: :utc_datetime)
  end

  def max_slots, do: @max_slots
  def max_participants, do: @max_participants

  @spec creation_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def creation_changeset(poll, attrs) do
    poll
    |> cast(attrs, [
      :user_id,
      :meeting_type_id,
      :title,
      :description,
      :duration_minutes,
      :deadline_at,
      :timezone
    ])
    |> validate_required([:user_id, :title, :duration_minutes, :timezone])
    |> validate_number(:duration_minutes, greater_than: 0, less_than_or_equal_to: 1440)
    |> validate_length(:title, max: 255)
    |> put_new_token()
    |> unique_constraint(:token)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:meeting_type_id)
  end

  @spec confirm_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def confirm_changeset(poll, attrs) do
    poll
    |> cast(attrs, [:status, :confirmed_meeting_id, :confirmed_at])
    |> validate_required([:status, :confirmed_meeting_id, :confirmed_at])
  end

  @spec cancel_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def cancel_changeset(poll), do: change(poll, status: :cancelled)

  defp put_new_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, UnguessableToken.generate())
      _token -> changeset
    end
  end
end
