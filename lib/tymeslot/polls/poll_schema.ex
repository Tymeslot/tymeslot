defmodule Tymeslot.Polls.PollSchema do
  @moduledoc "A meeting poll: proposed candidate slots that invitees vote on."

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
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

  @spec max_slots() :: pos_integer()
  def max_slots, do: @max_slots

  @spec max_participants() :: pos_integer()
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

  @doc """
  Changeset for a host editing a poll's wording after it exists.

  Deliberately narrow: only the title and description, never the candidate
  times, duration, timezone, or deadline. Guests vote against the slots they
  were shown, so changing those under an in-flight poll would silently
  invalidate votes already cast.
  """
  @spec details_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def details_changeset(poll, attrs) do
    poll
    |> cast(attrs, [:title, :description])
    # `cast/3` already nils a whitespace-only string, so these have to tolerate
    # nil as well as trim: a title of "   " arrives here as a nil *change*, and
    # `validate_required/2` is what turns it into an error.
    |> update_change(:title, &trim_to_nil/1)
    |> update_change(:description, &trim_to_nil/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 255)
    |> validate_length(:description, max: 2000)
  end

  @spec confirm_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def confirm_changeset(poll, attrs) do
    poll
    |> cast(attrs, [:status, :confirmed_meeting_id, :confirmed_at])
    |> validate_required([:status, :confirmed_meeting_id, :confirmed_at])
  end

  @spec cancel_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def cancel_changeset(poll), do: change(poll, status: :cancelled)

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_to_nil(value), do: value

  defp put_new_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, UnguessableToken.generate())
      _token -> changeset
    end
  end
end
