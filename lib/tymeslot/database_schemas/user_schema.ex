defmodule Tymeslot.DatabaseSchemas.UserSchema do
  @moduledoc """
  Schema for user accounts in the Tymeslot system.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.DatabaseSchemas.{
    CalendarIntegrationSchema,
    ProfileSchema,
    VideoIntegrationSchema
  }

  alias Tymeslot.Security.FieldValidators.EmailValidator
  alias Tymeslot.Security.Password

  @type t :: %__MODULE__{
          id: integer() | nil,
          email: String.t() | nil,
          password_hash: String.t() | nil,
          password: String.t() | nil,
          password_confirmation: String.t() | nil,
          verified_at: DateTime.t() | nil,
          verification_token: String.t() | nil,
          verification_sent_at: DateTime.t() | nil,
          verification_token_used_at: DateTime.t() | nil,
          signup_ip: String.t() | nil,
          reset_token_hash: String.t() | nil,
          reset_sent_at: DateTime.t() | nil,
          reset_token_used_at: DateTime.t() | nil,
          pending_email: String.t() | nil,
          email_change_token_hash: String.t() | nil,
          email_change_sent_at: DateTime.t() | nil,
          email_change_confirmed_at: DateTime.t() | nil,
          name: String.t() | nil,
          provider: String.t() | nil,
          provider_uid: String.t() | nil,
          provider_email: String.t() | nil,
          provider_meta: map() | nil,
          github_user_id: String.t() | nil,
          google_user_id: String.t() | nil,
          onboarding_completed_at: DateTime.t() | nil,
          profile: ProfileSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          calendar_integrations: [CalendarIntegrationSchema.t()] | Ecto.Association.NotLoaded.t(),
          video_integrations: [VideoIntegrationSchema.t()] | Ecto.Association.NotLoaded.t(),
          meeting_types: [any()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "users" do
    field(:email, :string)
    field(:password_hash, :string)
    field(:password, :string, virtual: true)
    field(:password_confirmation, :string, virtual: true)
    field(:verified_at, :utc_datetime)
    field(:verification_token, :string)
    field(:verification_sent_at, :utc_datetime)
    field(:verification_token_used_at, :utc_datetime)
    field(:signup_ip, :string)
    field(:reset_token_hash, :string)
    field(:reset_sent_at, :utc_datetime)
    field(:reset_token_used_at, :utc_datetime)
    field(:pending_email, :string)
    field(:email_change_token_hash, :string)
    field(:email_change_sent_at, :utc_datetime)
    field(:email_change_confirmed_at, :utc_datetime)
    field(:name, :string)
    field(:provider, :string)
    field(:provider_uid, :string)
    field(:provider_email, :string)
    field(:provider_meta, :map)
    field(:github_user_id, :string)
    field(:google_user_id, :string)
    field(:onboarding_completed_at, :utc_datetime)

    has_one(:profile, Tymeslot.DatabaseSchemas.ProfileSchema, foreign_key: :user_id)

    has_many(:calendar_integrations, Tymeslot.DatabaseSchemas.CalendarIntegrationSchema,
      foreign_key: :user_id
    )

    has_many(:video_integrations, Tymeslot.DatabaseSchemas.VideoIntegrationSchema,
      foreign_key: :user_id
    )

    has_many(:meeting_types, Tymeslot.DatabaseSchemas.MeetingTypeSchema, foreign_key: :user_id)

    timestamps()
  end

  @doc false
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :password,
      :password_confirmation,
      :name,
      :provider,
      :provider_uid,
      :provider_email,
      :provider_meta
    ])
    |> validate_required([:email])
    |> validate_email()
    |> validate_password()
    |> unique_constraint(:email)
    |> unique_constraint([:provider, :provider_uid])
  end

  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :password_confirmation, :name])
    |> validate_required([:email, :password, :password_confirmation])
    |> validate_email()
    |> validate_password()
    |> validate_confirmation(:password)
    |> unique_constraint(:email)
    |> put_password_hash()
  end

  @spec social_registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def social_registration_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :email,
      :name,
      :provider,
      :provider_uid,
      :provider_email,
      :provider_meta,
      :github_user_id,
      :google_user_id,
      :verified_at
    ])
    |> validate_required([:email])
    |> validate_email()
    |> unique_constraint(:email)
    |> unique_constraint([:provider, :provider_uid])
    |> unique_constraint(:github_user_id)
    |> unique_constraint(:google_user_id)
  end

  @spec password_reset_changeset(t(), map()) :: Ecto.Changeset.t()
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password, :password_confirmation])
    |> validate_password()
    |> validate_confirmation(:password)
    |> put_password_hash()
  end

  @doc """
  Changeset for initiating an email change request.
  Stores the new email in pending_email field and generates a token.
  """
  @spec email_change_request_changeset(t(), map()) :: Ecto.Changeset.t()
  def email_change_request_changeset(user, attrs) do
    user
    |> cast(attrs, [:pending_email, :email_change_token_hash])
    |> validate_required([:pending_email, :email_change_token_hash])
    |> validate_length(:pending_email, max: 160)
    |> validate_pending_email_format()
    |> validate_different_email()
    |> unsafe_validate_unique(:pending_email, Tymeslot.Repo, message: "is already registered")
    |> unique_constraint(:pending_email)
    |> unique_constraint(:email_change_token_hash)
    |> put_change(:email_change_sent_at, DateTime.truncate(DateTime.utc_now(), :second))
  end

  defp validate_pending_email_format(changeset) do
    validate_change(changeset, :pending_email, fn :pending_email, email ->
      case EmailValidator.validate(email) do
        :ok -> []
        {:error, message} -> [pending_email: message]
      end
    end)
  end

  @doc """
  Changeset for confirming an email change.
  Moves pending_email to email and clears temporary fields.
  """
  @spec email_change_confirm_changeset(t()) :: Ecto.Changeset.t()
  def email_change_confirm_changeset(user) do
    user
    |> change(%{
      email: user.pending_email,
      pending_email: nil,
      email_change_token_hash: nil,
      email_change_sent_at: nil,
      email_change_confirmed_at: DateTime.truncate(DateTime.utc_now(), :second)
    })
    |> unique_constraint(:email)
  end

  defp validate_different_email(changeset) do
    case get_field(changeset, :pending_email) do
      nil ->
        changeset

      pending_email ->
        if pending_email == changeset.data.email do
          add_error(changeset, :pending_email, "must be different from current email")
        else
          changeset
        end
    end
  end

  defp validate_email(changeset) do
    changeset
    |> validate_length(:email, max: 160)
    |> validate_change(:email, fn :email, email ->
      case EmailValidator.validate(email) do
        :ok -> []
        {:error, message} -> [email: message]
      end
    end)
  end

  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8, max: 80)
    |> validate_format(:password, ~r/[a-z]/,
      message: "must contain at least one lower case character"
    )
    |> validate_format(:password, ~r/[A-Z]/,
      message: "must contain at least one upper case character"
    )
    |> validate_format(:password, ~r/[0-9]/, message: "must contain at least one digit")
  end

  defp put_password_hash(changeset) do
    case changeset do
      %Ecto.Changeset{valid?: true, changes: %{password: password}} ->
        put_change(changeset, :password_hash, Password.hash_password(password))

      _ ->
        changeset
    end
  end
end
