defmodule Tymeslot.Meetings.ParticipantSchema do
  @moduledoc """
  Ecto schema for a participant on a group meeting.

  Solo meeting types (`max_participants == 1`) keep the `attendee_*` fields
  on the meeting row exactly as before. Group meetings instead carry one
  participant row per booker; each participant manages their own seat via an
  unguessable `management_token` and is soft-cancelled through
  `cancelled_at` so freed seats become bookable again.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.ChangesetValidators.Email, as: EmailChangeset
  alias Tymeslot.Locales
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.Token

  @type t :: %__MODULE__{
          id: binary() | nil,
          meeting_id: binary() | nil,
          name: String.t() | nil,
          email: String.t() | nil,
          phone: String.t() | nil,
          company: String.t() | nil,
          message: String.t() | nil,
          timezone: String.t() | nil,
          locale: String.t(),
          custom_field_answers: map(),
          management_token: String.t() | nil,
          management_token_hash: String.t() | nil,
          ical_sequence: non_neg_integer(),
          confirmation_sent_at: DateTime.t() | nil,
          organizer_notified_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          meeting: MeetingSchema.t() | Ecto.Association.NotLoaded.t() | nil,
          guests: [Tymeslot.Meetings.GuestSchema.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "meeting_participants" do
    field(:name, :string)
    field(:email, :string)
    field(:phone, :string)
    field(:company, :string)
    field(:message, :string)
    field(:timezone, :string)
    field(:locale, :string, default: "en")
    field(:custom_field_answers, :map, default: %{})
    # Every email to the participant rebuilds their seat links from this
    # token, so it is encrypted rather than only hashed, and looked up by
    # `management_token_hash`.
    field(:management_token, EncryptedString, source: :management_token_encrypted, redact: true)
    field(:management_token_hash, :string)
    # The seat's own calendar-file revision: each seat is its own event in
    # the participant's calendar.
    field(:ical_sequence, :integer, default: 0)
    field(:confirmation_sent_at, :utc_datetime)
    field(:organizer_notified_at, :utc_datetime)
    field(:cancelled_at, :utc_datetime)

    belongs_to(:meeting, MeetingSchema, type: :binary_id)

    has_many(:guests, Tymeslot.Meetings.GuestSchema,
      foreign_key: :participant_id,
      preload_order: [asc: :inserted_at]
    )

    timestamps(type: :utc_datetime)
  end

  @token_bytes 32

  @doc """
  Changeset for adding a participant to a group meeting.

  Normalises the email, validates its format the same way `MeetingSchema`
  validates `attendee_email`, and generates an unguessable
  `management_token` when one is not already present.
  """
  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(participant, attrs) do
    participant
    |> cast(attrs, [
      :meeting_id,
      :name,
      :email,
      :phone,
      :company,
      :message,
      :timezone,
      :locale,
      :custom_field_answers,
      :management_token
    ])
    |> update_change(:email, &normalize_email/1)
    |> validate_required([:meeting_id, :name, :email, :timezone, :locale])
    |> EmailChangeset.validate_email(:email)
    |> validate_inclusion(:locale, supported_locale_codes(), message: "is not a supported locale")
    |> ensure_management_token()
    |> Token.put_hash(:management_token, :management_token_hash)
    |> unique_constraint(:management_token_hash)
    # One live seat per address per slot. Without it, submitting the booking
    # form from two tabs quietly consumes two seats and issues two management
    # tokens, so cancelling "the" booking only frees half of it.
    |> unique_constraint([:meeting_id, :email],
      name: :meeting_participants_live_email_index,
      message: "already has a spot at this time"
    )
    |> foreign_key_constraint(:meeting_id)
  end

  @doc """
  Changeset for soft-cancelling a participant at the given time.

  Cancelling the seat is a new revision of its calendar entry (the
  cancellation the participant and their guests are sent), so
  `ical_sequence` advances with it, in the same write: a cancelled seat
  stores the revision of its own cancellation. See `invitation_sequence/1`.
  """
  @spec cancel_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def cancel_changeset(participant, cancelled_at) do
    change(participant, cancelled_at: cancelled_at, ical_sequence: participant.ical_sequence + 1)
  end

  @doc """
  The UID of this seat's own calendar entry.

  Each seat is its own event in the participant's calendar (and their
  guests'), never the slot's `calendar_uid`, which names the organiser's
  provider event. The participant id is a UUID like `calendar_uid`, stable for
  the seat's life and never reused: a seat cancelled and booked again by the
  same person is a new row, so a new event rather than a revival of the
  cancelled one.
  """
  @spec calendar_uid(t()) :: String.t()
  def calendar_uid(%__MODULE__{id: id}) when is_binary(id), do: id

  @doc """
  The revision of the last invitation sent for this seat's calendar entry.

  A live seat's stored `ical_sequence` is exactly that. A cancelled seat
  stores the revision of its cancellation (`cancel_changeset/2` advances it),
  so its last invitation is the one before, which is what a cancellation
  payload carries: the cancellation file is stamped one above it.
  """
  @spec invitation_sequence(t()) :: non_neg_integer()
  def invitation_sequence(%__MODULE__{cancelled_at: nil, ical_sequence: sequence}), do: sequence
  def invitation_sequence(%__MODULE__{ical_sequence: sequence}), do: max(sequence - 1, 0)

  @doc "True while the participant still holds their seat (not cancelled)."
  @spec live?(t()) :: boolean()
  def live?(%__MODULE__{cancelled_at: nil}), do: true
  def live?(%__MODULE__{}), do: false

  @doc "Generates an unguessable, URL-safe management token."
  @spec generate_token() :: String.t()
  def generate_token do
    @token_bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp ensure_management_token(changeset) do
    case get_field(changeset, :management_token) do
      nil -> put_change(changeset, :management_token, generate_token())
      _present -> changeset
    end
  end

  @doc "An email address as a participant row stores it: trimmed and lower-cased."
  @spec normalize_email(String.t() | nil) :: String.t() | nil
  def normalize_email(nil), do: nil

  def normalize_email(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  defp supported_locale_codes, do: Locales.supported_codes()
end
