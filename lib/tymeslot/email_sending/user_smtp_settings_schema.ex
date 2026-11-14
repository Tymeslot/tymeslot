defmodule Tymeslot.EmailSending.UserSmtpSettingsSchema do
  @moduledoc """
  One SMTP identity owned by a user. Submitted attributes cannot change
  ownership, activation, revision, or evidence that a test succeeded.
  """

  use Ecto.Schema
  use Gettext, backend: TymeslotWeb.Gettext

  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email
  alias Tymeslot.EmailSending.Destination
  alias Tymeslot.Security.Encryption

  @type t :: %__MODULE__{}
  @fields [:host, :port, :security, :username, :password, :from_address, :from_name]
  @credentials [:username_encrypted, :password_encrypted]
  @controls ~r/[\x00-\x1f\x7f]/u

  schema "user_smtp_settings" do
    belongs_to(:user, Tymeslot.Auth.UserSchema)
    field(:host, :string)
    field(:port, :integer)
    field(:security, Ecto.Enum, values: [:implicit_tls, :starttls])
    field(:username_encrypted, :binary, redact: true)
    field(:password_encrypted, :binary, redact: true)
    field(:username, :string, virtual: true, redact: true)
    field(:password, :string, virtual: true, redact: true)
    field(:from_address, :string)
    field(:from_name, :string)
    field(:enabled, :boolean, default: false)
    field(:revision, :integer, default: 1)
    field(:tested_revision, :integer)
    field(:tested_at, :utc_datetime_usec)
    field(:last_error, :string)
    field(:last_failed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Validates editable settings, retaining stored secrets for blank edits."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, @fields)
    |> validate_encoding()
    |> validate_controls()
    |> update_change(:host, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:from_address, &String.trim/1)
    |> update_change(:from_name, &String.trim/1)
    |> validate_required([:host, :port, :security, :from_address, :from_name])
    |> validate_length(:host, max: 253, count: :bytes)
    |> validate_length(:from_name, max: 255, count: :bytes)
    |> validate_length(:username, max: 1024, count: :bytes)
    |> validate_length(:password, max: 4096, count: :bytes)
    |> validate_inclusion(:port, [465, 587])
    |> validate_security()
    |> Email.validate_email(:from_address)
    |> validate_host()
    |> require_credential(:username, :username_encrypted)
    |> require_credential(:password, :password_encrypted)
    |> unique_constraint(:user_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Encrypts valid credential changes immediately before persistence."
  @spec encrypt_credentials(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def encrypt_credentials(%Ecto.Changeset{valid?: true} = changeset) do
    Enum.reduce([username: :username_encrypted, password: :password_encrypted], changeset, fn
      {plain, encrypted}, acc ->
        case fetch_change(acc, plain) do
          {:ok, value} ->
            acc |> put_change(encrypted, Encryption.encrypt(value)) |> delete_change(plain)

          :error ->
            acc
        end
    end)
  end

  def encrypt_credentials(changeset), do: changeset

  @doc "The ciphertext columns included in the credential rotation sweep."
  @spec encrypted_credential_fields() :: [atom()]
  def encrypted_credential_fields, do: @credentials

  defp require_credential(changeset, plain, encrypted) do
    if get_field(changeset, encrypted), do: changeset, else: validate_required(changeset, [plain])
  end

  defp validate_security(changeset) do
    case {get_field(changeset, :port), get_field(changeset, :security)} do
      {465, :implicit_tls} ->
        changeset

      {587, :starttls} ->
        changeset

      {port, security} when port in [465, 587] and not is_nil(security) ->
        add_error(
          changeset,
          :security,
          dgettext_noop("errors", "must match the selected SMTP port")
        )

      _missing_or_invalid ->
        changeset
    end
  end

  defp validate_controls(changeset) do
    Enum.reduce([:host, :username, :password, :from_address, :from_name], changeset, fn field,
                                                                                        acc ->
      validate_change(acc, field, fn _field, value ->
        if Regex.match?(@controls, value),
          do: [{field, dgettext_noop("errors", "must not contain control characters")}],
          else: []
      end)
    end)
  end

  # Ecto accepts binaries for string fields without checking their encoding.
  # Remove invalid changes before normalization and Unicode validators run;
  # the error still makes the candidate unusable even when an old value exists.
  defp validate_encoding(changeset) do
    Enum.reduce([:host, :username, :password, :from_address, :from_name], changeset, fn field,
                                                                                        acc ->
      case fetch_change(acc, field) do
        {:ok, value} when is_binary(value) ->
          if String.valid?(value) do
            acc
          else
            acc
            |> delete_change(field)
            |> add_error(field, dgettext_noop("errors", "must be valid UTF-8"))
          end

        _unchanged_or_not_binary ->
          acc
      end
    end)
  end

  defp validate_host(changeset) do
    validate_change(changeset, :host, fn _field, host ->
      if Destination.valid_host?(host),
        do: [],
        else: [host: dgettext_noop("errors", "must be a public SMTP hostname")]
    end)
  end
end
