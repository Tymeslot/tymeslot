defmodule Tymeslot.Auth.UserSchema do
  @moduledoc """
  Schema for user accounts in the Tymeslot system.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Locales
  alias Tymeslot.Profiles.ProfileSchema

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.Security.FieldValidators.PasswordValidator
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
          dashboard_tour_seen_at: DateTime.t() | nil,
          dashboard_setup_done_items: [String.t()],
          dashboard_setup_dismissed_at: DateTime.t() | nil,
          last_active_at: DateTime.t() | nil,
          is_admin: boolean(),
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
    field(:password, :string, virtual: true, redact: true)
    field(:password_confirmation, :string, virtual: true, redact: true)
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
    field(:dashboard_tour_seen_at, :utc_datetime)
    field(:dashboard_setup_done_items, {:array, :string}, default: [])
    field(:dashboard_setup_dismissed_at, :utc_datetime)
    field(:last_active_at, :utc_datetime)
    field(:is_admin, :boolean, default: false)
    field(:locale, :string)

    has_one(:profile, Tymeslot.Profiles.ProfileSchema, foreign_key: :user_id)

    has_many(:calendar_integrations, Tymeslot.Integrations.Calendar.CalendarIntegrationSchema,
      foreign_key: :user_id
    )

    has_many(:video_integrations, Tymeslot.Integrations.Video.VideoIntegrationSchema,
      foreign_key: :user_id
    )

    has_many(:meeting_types, Tymeslot.MeetingTypes.MeetingTypeSchema, foreign_key: :user_id)

    timestamps(type: :utc_datetime)
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
    |> update_change(:email, &String.downcase/1)
    |> validate_email()
    |> validate_password()
    |> unique_constraint(:email)
    |> unique_constraint([:provider, :provider_uid])
  end

  @doc """
  Changeset for the user's interface language preference. An empty string or
  `nil` clears the preference (fall back to browser/session detection); any
  other value must be a supported locale code.
  """
  @spec locale_changeset(t(), map()) :: Ecto.Changeset.t()
  def locale_changeset(user, attrs) do
    user
    |> cast(attrs, [:locale])
    |> update_change(:locale, fn locale -> if locale in ["", nil], do: nil, else: locale end)
    |> validate_inclusion(:locale, Locales.supported_codes(),
      message: "is not a supported locale"
    )
  end

  @spec registration_changeset(t(), map()) :: Ecto.Changeset.t()
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :password_confirmation, :name])
    |> validate_required([:email, :password, :password_confirmation])
    |> update_change(:email, &String.downcase/1)
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
    |> update_change(:email, &String.downcase/1)
    |> validate_email()
    |> unique_constraint(:email)
    |> unique_constraint([:provider, :provider_uid])
    |> unique_constraint(:github_user_id)
    |> unique_constraint(:google_user_id)
  end

  @doc """
  Internal-only changeset for toggling admin status. Never call from user-submitted params —
  `:is_admin` must only flip via the mix tasks, release helpers, or the admin UI which already
  enforces an admin-only path.
  """
  @spec admin_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def admin_changeset(user, is_admin) when is_boolean(is_admin) do
    change(user, %{is_admin: is_admin})
  end

  @doc """
  Changeset for setting a new password, whether through a reset link or from
  the account page. A password change revokes every outstanding credential
  token (see `revoke_credential_tokens/1`).
  """
  @spec password_reset_changeset(t(), map()) :: Ecto.Changeset.t()
  def password_reset_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password, :password_confirmation])
    |> validate_password()
    |> validate_confirmation(:password)
    |> put_password_hash()
    |> revoke_credential_tokens()
  end

  @doc """
  Blanks the virtual password fields on the user a successful password write
  returns. `Repo.update/1` copies every change into the returned struct,
  virtual fields included, so without this the caller would receive (and
  might pass on) the plaintext password.
  """
  @spec drop_plaintext_password({:ok, t()} | {:error, Ecto.Changeset.t()}) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def drop_plaintext_password({:ok, %__MODULE__{} = user}),
    do: {:ok, %{user | password: nil, password_confirmation: nil}}

  def drop_plaintext_password({:error, _changeset} = error), do: error

  @doc """
  Clears every outstanding token that could change the account's credentials:
  a pending password reset and a pending email change.

  Applied whenever the credentials themselves change (password reset, password
  update, confirmed email change). Without it, a token issued before the change
  outlives it: someone who knew the old password could request an email change
  to their own address, and still confirm it after the owner reset the
  password to lock them out. `reset_token_used_at` is left alone so the audit
  trail of a consumed reset survives.
  """
  @credential_token_fields [
    :reset_token_hash,
    :reset_sent_at,
    :pending_email,
    :email_change_token_hash,
    :email_change_sent_at
  ]

  @spec revoke_credential_tokens(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def revoke_credential_tokens(%Ecto.Changeset{} = changeset) do
    # `force_change/3`, not `change/2`: `change/2` drops a change equal to the
    # struct's current value, so a caller holding a stale user (one loaded
    # before a token was issued, where the field still reads nil) would write
    # nothing and leave the newer token live.
    Enum.reduce(@credential_token_fields, changeset, &force_change(&2, &1, nil))
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
    |> update_change(:pending_email, &String.downcase/1)
    |> EmailChangeset.validate_email(:pending_email)
    |> validate_different_email()
    |> unsafe_validate_unique(:pending_email, Tymeslot.Repo, message: "is already registered")
    |> unique_constraint(:pending_email)
    |> unique_constraint(:email_change_token_hash)
    |> put_change(:email_change_sent_at, DateTime.utc_now(:second))
  end

  @doc """
  Changeset for confirming an email change.
  Moves pending_email to email and revokes every outstanding credential token,
  including a reset link mailed to the old address.
  """
  @spec email_change_confirm_changeset(t()) :: Ecto.Changeset.t()
  def email_change_confirm_changeset(user) do
    user
    |> change(%{
      email: user.pending_email,
      email_change_confirmed_at: DateTime.utc_now(:second)
    })
    |> revoke_credential_tokens()
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
    EmailChangeset.validate_email(changeset, :email)
  end

  defp validate_password(changeset) do
    validate_change(changeset, :password, fn :password, password ->
      case PasswordValidator.validate(password) do
        :ok -> []
        {:error, message} -> [password: message]
      end
    end)
  end

  defp put_password_hash(changeset) do
    case changeset do
      %Ecto.Changeset{valid?: true, changes: %{password: password}} ->
        put_change(changeset, :password_hash, Password.hash_password(password))

      _other ->
        changeset
    end
  end
end
