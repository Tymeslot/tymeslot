defmodule Tymeslot.Invitations.InvitationSchema do
  @moduledoc """
  A single-use link to book an invitation-only meeting type.

  The token is held encrypted, so the host can be shown the link again, and
  looked up by its hash. Whether the invitation is available, used, expired or
  revoked is derived (`Tymeslot.Invitations.InvitationStatus`), never stored.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.Clock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.Token

  @type t :: %__MODULE__{}

  @max_name_length 100

  schema "meeting_type_invitations" do
    field(:token, EncryptedString, source: :token_encrypted, redact: true)
    field(:token_hash, :string)
    field(:name, :string)
    field(:email, :string)
    field(:expires_at, :utc_datetime)
    field(:release_on_cancel, :boolean, default: true)
    field(:revoked_at, :utc_datetime)
    field(:reopened_at, :utc_datetime)

    belongs_to(:meeting_type, MeetingTypeSchema)
    belongs_to(:user, Tymeslot.Auth.UserSchema)
    has_many(:meetings, MeetingSchema, foreign_key: :invitation_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds an invitation from the host's input: an optional name and address that
  prefill the booking form, an optional expiry and the release-on-cancel choice.
  """
  @spec creation_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def creation_changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:name, :email, :expires_at, :release_on_cancel])
    |> update_change(:name, &clean/1)
    |> update_change(:email, &(&1 |> clean() |> lowercase()))
    |> validate_length(:name, max: @max_name_length)
    |> validate_length(:email, max: 255)
    |> EmailChangeset.validate_email(:email)
    |> validate_expiry()
    |> put_new_token()
    |> Token.put_hash(:token, :token_hash)
    |> unique_constraint(:token_hash)
  end

  @doc "Marks the invitation revoked at `now`."
  @spec revoke_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def revoke_changeset(invitation, now),
    do: change(invitation, revoked_at: DateTime.truncate(now, :second))

  @doc "Reopens the invitation at `now`: meetings booked earlier stop counting."
  @spec reopen_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def reopen_changeset(invitation, now),
    do: change(invitation, reopened_at: DateTime.truncate(now, :second), revoked_at: nil)

  defp clean(nil), do: nil

  defp clean(value) when is_binary(value) do
    case value |> String.replace("\x00", "") |> String.trim() do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp lowercase(nil), do: nil
  defp lowercase(value), do: String.downcase(value)

  defp validate_expiry(changeset) do
    validate_change(changeset, :expires_at, fn :expires_at, expires_at ->
      if DateTime.compare(expires_at, Clock.utc_now()) == :gt,
        do: [],
        else: [expires_at: "must be in the future"]
    end)
  end

  defp put_new_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, Token.generate(24))
      _token -> changeset
    end
  end
end
