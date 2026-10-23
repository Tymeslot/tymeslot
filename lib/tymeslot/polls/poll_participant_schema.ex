defmodule Tymeslot.Polls.PollParticipantSchema do
  @moduledoc """
  A person who asked to vote on a poll via the shared link.

  Their personal `?p=` link reaches them only by email, so holding it proves
  they own the address. Until they first save responses through it they are
  unconfirmed: they do not count anywhere (`PollSchema`'s `:participants` leaves
  them out), and once their link is older than `unconfirmed_ttl_seconds/0`
  it stops working and the row is pruned.

  A participant the host invited by address is confirmed from the start: the
  host vouches for the address, and the invitation carries the link. They may
  have no name until they first vote.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.Locales
  alias Tymeslot.Polls.{PollSchema, PollVoteSchema}
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.FieldValidators.NameValidator
  alias Tymeslot.Security.Token
  alias Tymeslot.Timezones

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  # How long an unconfirmed participant's link stays valid, counted from the
  # last time it was sent.
  @unconfirmed_ttl_seconds 48 * 60 * 60

  schema "poll_participants" do
    field(:name, :string)
    field(:email, :string)
    # The per-person `?p=` token. Asking again with the same address emails the
    # same link again, so the token is encrypted rather than only hashed; it is
    # looked up by `token_hash`.
    field(:token, EncryptedString, source: :token_encrypted, redact: true)
    field(:token_hash, :string)
    field(:timezone, :string)
    field(:locale, :string, default: "en")
    field(:voted_at, :utc_datetime)
    # When the participant first saved responses through their emailed link.
    # Nil until then; their responses count only once it is set.
    field(:confirmed_at, :utc_datetime)
    # When their link was last emailed: throttles repeat requests and starts
    # the clock on an unconfirmed participant's link.
    field(:link_sent_at, :utc_datetime)
    # When the host invited them by address; nil for someone who asked for a
    # link on the voting page.
    field(:invited_at, :utc_datetime)

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
    |> validate_required([:name])
    |> common_creation()
  end

  @doc """
  Builds a participant the host invited by address, with the name they gave
  if any. Confirmed at once, since the host vouches for the address; the
  caller stamps `link_sent_at` as the invitation goes out.
  """
  @spec invitation_changeset(%__MODULE__{}, map(), DateTime.t()) :: Ecto.Changeset.t()
  def invitation_changeset(participant, attrs, now) do
    now = DateTime.truncate(now, :second)

    participant
    |> cast(attrs, [:poll_id, :name, :email, :timezone, :locale])
    |> put_change(:confirmed_at, now)
    |> put_change(:invited_at, now)
    |> common_creation()
  end

  defp common_creation(changeset) do
    changeset
    |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
    |> update_change(:name, &String.trim/1)
    |> validate_required([:poll_id, :email])
    |> EmailChangeset.validate_email(:email)
    |> validate_length(:email, max: 255)
    |> validate_name()
    |> validate_timezone()
    |> validate_locale()
    |> put_new_token()
    |> Token.put_hash(:token, :token_hash)
    |> unique_constraint(:token_hash)
    |> unique_constraint([:poll_id, :email], name: :poll_participants_poll_id_email_index)
    |> foreign_key_constraint(:poll_id)
  end

  @doc """
  Sets the name of a participant invited without one, as they give it the
  first time they vote.
  """
  @spec name_changeset(%__MODULE__{}, String.t() | nil) :: Ecto.Changeset.t()
  def name_changeset(participant, name) do
    participant
    |> cast(%{name: name}, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_name()
  end

  @doc "The participant as an email recipient: with their name once they have one."
  @spec email_recipient(%__MODULE__{}) :: {String.t(), String.t()} | String.t()
  def email_recipient(%__MODULE__{name: name, email: email}) when is_binary(name) and name != "",
    do: {name, email}

  def email_recipient(%__MODULE__{email: email}), do: email

  @doc "The participant's name, or their address while they have none."
  @spec display_name(%__MODULE__{}) :: String.t()
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "", do: name
  def display_name(%__MODULE__{email: email}), do: email

  @doc "How long an unconfirmed participant's link stays valid after it was last sent."
  @spec unconfirmed_ttl_seconds() :: pos_integer()
  def unconfirmed_ttl_seconds, do: @unconfirmed_ttl_seconds

  @doc """
  Stamps `voted_at`, and `confirmed_at` the first time: saving responses
  through the emailed link is what confirms the address.
  """
  @spec voted_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def voted_changeset(participant, voted_at) do
    voted_at = DateTime.truncate(voted_at, :second)

    participant
    |> change(voted_at: voted_at)
    |> put_confirmed_at(participant.confirmed_at, voted_at)
  end

  defp put_confirmed_at(changeset, nil, at), do: put_change(changeset, :confirmed_at, at)
  defp put_confirmed_at(changeset, _confirmed_at, _at), do: changeset

  @doc "Confirms and marks invited a participant who asked for a link before the host invited them."
  @spec invited_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def invited_changeset(participant, now) do
    now = DateTime.truncate(now, :second)
    change(participant, confirmed_at: now, invited_at: now)
  end

  @doc "Stamps `link_sent_at` on a participant or on a changeset building one."
  @spec link_sent_changeset(%__MODULE__{} | Ecto.Changeset.t(), DateTime.t()) ::
          Ecto.Changeset.t()
  def link_sent_changeset(participant_or_changeset, sent_at) do
    change(participant_or_changeset, link_sent_at: DateTime.truncate(sent_at, :second))
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
      nil -> put_change(changeset, :token, Token.generate(24))
      _token -> changeset
    end
  end
end
