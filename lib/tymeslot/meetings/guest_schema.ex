defmodule Tymeslot.Meetings.GuestSchema do
  @moduledoc """
  Ecto schema for a guest added to a meeting during booking.

  Guests are additional invitees the primary attendee adds when booking. Each
  guest receives a confirmation email with a tokenised RSVP link and can accept
  or decline independently of the primary attendee; their response is reflected
  on the organiser's dashboard.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.Meetings.MeetingSchema

  @type t :: %__MODULE__{
          id: binary() | nil,
          meeting_id: binary() | nil,
          email: String.t() | nil,
          name: String.t() | nil,
          status: String.t(),
          rsvp_token: String.t() | nil,
          responded_at: DateTime.t() | nil,
          confirmation_sent_at: DateTime.t() | nil,
          meeting: MeetingSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meeting_guests" do
    field(:email, :string)
    field(:name, :string)
    field(:status, :string, default: "pending")
    field(:rsvp_token, :string)
    field(:responded_at, :utc_datetime)
    field(:confirmation_sent_at, :utc_datetime)

    belongs_to(:meeting, MeetingSchema, type: :binary_id)

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(pending accepted declined)
  @token_bytes 24

  @doc """
  Changeset for adding a guest to a meeting.

  Normalises the email, validates its format, defaults the status to
  `"pending"`, and generates an unguessable `rsvp_token` when one is not
  already present.
  """
  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(guest, attrs) do
    guest
    |> cast(attrs, [:email, :name, :meeting_id, :status])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:email, :meeting_id])
    |> EmailChangeset.validate_email(:email)
    |> ensure_status()
    |> validate_inclusion(:status, @valid_statuses)
    |> ensure_rsvp_token()
    |> unique_constraint(:rsvp_token)
    |> unique_constraint([:meeting_id, :email],
      name: :meeting_guests_meeting_id_email_index,
      message: "has already been added"
    )
    |> foreign_key_constraint(:meeting_id)
  end

  @doc """
  Changeset for recording a guest's RSVP response.

  Only the `status` and `responded_at` fields are writable here.
  """
  @spec rsvp_changeset(t(), map()) :: Ecto.Changeset.t()
  def rsvp_changeset(guest, attrs) do
    guest
    |> cast(attrs, [:status, :responded_at])
    |> validate_required([:status])
    |> validate_inclusion(:status, @valid_statuses)
  end

  @doc "Changeset for stamping the confirmation email as sent."
  @spec confirmation_sent_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def confirmation_sent_changeset(guest, sent_at) do
    cast(guest, %{confirmation_sent_at: sent_at}, [:confirmation_sent_at])
  end

  @doc "Returns the list of valid RSVP status values."
  @spec valid_statuses() :: [String.t()]
  def valid_statuses, do: @valid_statuses

  @typedoc "Aggregate RSVP counts for a list of guests."
  @type summary :: %{
          total: non_neg_integer(),
          accepted: non_neg_integer(),
          declined: non_neg_integer(),
          pending: non_neg_integer()
        }

  @doc "A zeroed RSVP summary accumulator."
  @spec empty_summary() :: summary()
  def empty_summary, do: %{total: 0, accepted: 0, declined: 0, pending: 0}

  @doc """
  Maps an RSVP status string to its summary bucket key.

  Anything other than `"accepted"`/`"declined"` (i.e. `"pending"` or an
  unexpected value) buckets as `:pending`.
  """
  @spec status_key(String.t()) :: :accepted | :declined | :pending
  def status_key("accepted"), do: :accepted
  def status_key("declined"), do: :declined
  def status_key(_pending), do: :pending

  @doc "Generates an unguessable, URL-safe RSVP token."
  @spec generate_token() :: String.t()
  def generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp ensure_status(changeset) do
    case get_field(changeset, :status) do
      nil -> put_change(changeset, :status, "pending")
      _present -> changeset
    end
  end

  defp ensure_rsvp_token(changeset) do
    case get_field(changeset, :rsvp_token) do
      nil -> put_change(changeset, :rsvp_token, generate_token())
      _present -> changeset
    end
  end

  defp normalize_email(nil), do: nil

  defp normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end
end
