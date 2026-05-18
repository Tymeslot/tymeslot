defmodule Tymeslot.Announcements.UserSeenAnnouncementSchema do
  @moduledoc """
  Records that a user has seen a specific feature announcement.
  Inserted via `Tymeslot.Announcements.mark_seen!/2`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          announcement_key: String.t() | nil,
          seen_at: DateTime.t() | nil
        }

  schema "user_seen_announcements" do
    belongs_to :user, UserSchema
    field :announcement_key, :string
    field :seen_at, :utc_datetime
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = record, attrs) do
    record
    |> cast(attrs, [:user_id, :announcement_key, :seen_at])
    |> validate_required([:user_id, :announcement_key, :seen_at])
    |> unique_constraint([:user_id, :announcement_key])
    |> foreign_key_constraint(:user_id)
  end
end
