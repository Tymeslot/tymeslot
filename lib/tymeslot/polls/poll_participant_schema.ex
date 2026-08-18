defmodule Tymeslot.Polls.PollParticipantSchema do
  @moduledoc "A person who registered to vote on a poll via the shared link."

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.Locales
  alias Tymeslot.Polls.{PollSchema, PollVoteSchema}
  alias Tymeslot.Security.FieldValidators.NameValidator
  alias Tymeslot.Timezones
  alias Tymeslot.Utils.UnguessableToken

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

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

  @doc """
  Builds a participant from public, unauthenticated form input.

  Every field here arrives from a stranger holding the poll link, so each one is
  normalised before validation and validated against the same shared rules the
  rest of the app uses: `EmailValidator` for the address (not a hand-rolled
  regex), `NameValidator` for the display name, and real IANA/locale lookups for
  `timezone` and `locale`, which were previously cast straight through and could
  hold arbitrary strings that later reach email rendering and time formatting.
  """
  @spec creation_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def creation_changeset(participant, attrs) do
    participant
    |> cast(attrs, [:poll_id, :name, :email, :timezone, :locale])
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:name, &String.trim/1)
    |> validate_required([:poll_id, :name, :email])
    |> EmailChangeset.validate_email(:email)
    |> validate_length(:email, max: 255)
    |> validate_name()
    |> validate_timezone()
    |> validate_locale()
    |> put_new_token()
    |> unique_constraint(:token)
    |> unique_constraint([:poll_id, :email], name: :poll_participants_poll_id_email_index)
    |> foreign_key_constraint(:poll_id)
  end

  @spec voted_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def voted_changeset(participant, voted_at) do
    change(participant, voted_at: DateTime.truncate(voted_at, :second))
  end

  defp validate_name(changeset) do
    validate_change(changeset, :name, fn _field, name ->
      case NameValidator.validate(name) do
        :ok -> []
        {:error, message} -> [name: message]
      end
    end)
  end

  # An unknown zone would crash date formatting later; fall back rather than
  # store it, since the timezone is a convenience, not something the guest typed.
  defp validate_timezone(changeset) do
    case get_change(changeset, :timezone) do
      nil -> changeset
      tz -> if Timezones.valid?(tz), do: changeset, else: delete_change(changeset, :timezone)
    end
  end

  defp validate_locale(changeset) do
    case get_change(changeset, :locale) do
      nil ->
        changeset

      locale ->
        if locale in Locales.supported_codes(),
          do: changeset,
          else: delete_change(changeset, :locale)
    end
  end

  defp put_new_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, UnguessableToken.generate())
      _token -> changeset
    end
  end
end
