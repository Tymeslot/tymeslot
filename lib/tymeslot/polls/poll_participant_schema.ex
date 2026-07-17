defmodule Tymeslot.Polls.PollParticipantSchema do
  @moduledoc "A person who registered to vote on a poll via the shared link."

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Polls.{PollSchema, PollVoteSchema}
  alias Tymeslot.Utils.UnguessableToken

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "poll_participants" do
    field(:name, :string)
    field(:email, :string)
    field(:token, :string)
    field(:timezone, :string)
    field(:locale, :string, default: "en")
    field(:voted_at, :utc_datetime)

    belongs_to(:poll, PollSchema)
    has_many(:votes, PollVoteSchema, foreign_key: :poll_participant_id)

    timestamps(type: :utc_datetime)
  end

  @spec creation_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def creation_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:poll_id, :name, :email, :timezone, :locale])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> validate_required([:poll_id, :name, :email])
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/)
    |> validate_length(:name, max: 255)
    |> put_new_token()
    |> unique_constraint(:token)
    |> unique_constraint([:poll_id, :email], name: :poll_participants_poll_id_email_index)
    |> foreign_key_constraint(:poll_id)
  end

  @spec voted_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def voted_changeset(participant, voted_at) do
    change(participant, voted_at: DateTime.truncate(voted_at, :second))
  end

  defp put_new_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, UnguessableToken.generate())
      _token -> changeset
    end
  end
end
