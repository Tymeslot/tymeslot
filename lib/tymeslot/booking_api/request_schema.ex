defmodule Tymeslot.BookingApi.RequestSchema do
  @moduledoc """
  Ecto schema for one idempotency key presented to the booking API.

  A row is the caller's claim on a key. It is inserted before the booking is
  attempted and carries `meeting_id` once the booking succeeds, which is what
  lets a retried request be answered with the meeting the first attempt created
  instead of booking the attendee a second time.

  Keys are scoped to the organiser: two callers integrating with two different
  organisers cannot collide, and neither can learn anything about the other's
  keys.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          idempotency_key: String.t() | nil,
          meeting_id: Ecto.UUID.t() | nil,
          user: Tymeslot.Auth.UserSchema.t() | Ecto.Association.NotLoaded.t(),
          meeting: Tymeslot.Meetings.MeetingSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "booking_api_requests" do
    field(:idempotency_key, :string)

    belongs_to(:user, Tymeslot.Auth.UserSchema)
    belongs_to(:meeting, Tymeslot.Meetings.MeetingSchema, type: :binary_id)

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset claiming `idempotency_key` for an organiser."
  @spec claim_changeset(map()) :: Ecto.Changeset.t()
  def claim_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [:user_id, :idempotency_key])
    |> validate_required([:user_id, :idempotency_key])
    |> validate_length(:idempotency_key, min: 1, max: 255)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:idempotency_key,
      name: :booking_api_requests_user_id_idempotency_key_index
    )
  end

  @doc "Changeset recording the meeting a claimed key produced."
  @spec meeting_changeset(t(), Ecto.UUID.t()) :: Ecto.Changeset.t()
  def meeting_changeset(request, meeting_id) do
    request
    |> cast(%{meeting_id: meeting_id}, [:meeting_id])
    |> validate_required([:meeting_id])
    |> foreign_key_constraint(:meeting_id)
  end
end
