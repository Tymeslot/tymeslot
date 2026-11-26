defmodule Tymeslot.Meetings.ParticipantSchema do
  @moduledoc """
  Ecto schema for a participant on a group meeting.

  Solo meeting types (`max_participants == 1`) keep the `attendee_*` fields on
  the meeting row. Group meetings instead carry one participant row per booker;
  each participant manages their own seat via an unguessable `management_token`
  and is soft-cancelled through `cancelled_at` so freed seats become bookable
  again.
  """

  use Gettext, backend: TymeslotWeb.Gettext
  use Ecto.Schema
  import Ecto.Changeset

  alias Tymeslot.Meetings.BookerContact
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.Token

  @type t :: %__MODULE__{
          id: binary() | nil,
          meeting_id: binary() | nil,
          series_id: binary() | nil,
          series_position: integer() | nil,
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
          notified_end_time: DateTime.t() | nil,
          confirmation_sent_at: DateTime.t() | nil,
          organizer_notified_at: DateTime.t() | nil,
          cancelled_at: DateTime.t() | nil,
          verification_deadline_at: DateTime.t() | nil,
          email_verified_at: DateTime.t() | nil,
          verification_emails_sent: pos_integer() | nil,
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
    # The end this seat was last told by an end change notice, or held before
    # a change not yet announced; nil when it knows the meeting as booked or
    # last rescheduled. Written only by the end change and reschedule paths.
    field(:notified_end_time, :utc_datetime)
    field(:confirmation_sent_at, :utc_datetime)
    field(:organizer_notified_at, :utc_datetime)
    field(:cancelled_at, :utc_datetime)
    # Both nil is an ungated seat. A deadline with no verification time is a
    # seat held until its booker confirms their address.
    field(:verification_deadline_at, :utc_datetime)
    field(:email_verified_at, :utc_datetime)
    # Verification emails sent to a held seat, `nil` meaning only the one
    # sent with the booking. Written only by `ParticipantQueries.count_verification_email/3`.
    field(:verification_emails_sent, :integer)

    belongs_to(:meeting, MeetingSchema, type: :binary_id)

    # The booking series this seat is an occurrence of; read
    # `series_position` only together with `series_id`.
    belongs_to(:series, Tymeslot.BookingSeries.SeriesSchema, type: :binary_id)
    field(:series_position, :integer)

    has_many(:guests, Tymeslot.Meetings.GuestSchema,
      foreign_key: :participant_id,
      preload_order: [asc: :inserted_at]
    )

    # The payment of a paid seat (`seat_payment: true`); none for a free one.
    # It follows a moved seat to its new participant.
    has_one(:booking_payment, Tymeslot.MeetingPayments.BookingPaymentSchema,
      foreign_key: :participant_id
    )

    timestamps(type: :utc_datetime)
  end

  @token_bytes 32

  @doc """
  Changeset for adding a participant to a group meeting.

  Normalises the email, validates its format the same way `MeetingSchema`
  validates `attendee_email`, and generates an unguessable
  `management_token` when one is not already present. A seat booked as one
  session of a series (`Tymeslot.BookingSeries`) carries `series_id` and
  `series_position`, set here, on insert, and never changed afterwards.
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
      :management_token,
      :verification_deadline_at,
      :email_verified_at,
      :series_id,
      :series_position
    ])
    |> validate_required([:meeting_id])
    |> BookerContact.validate()
    |> ensure_management_token()
    |> Token.put_hash(:management_token, :management_token_hash)
    |> unique_constraint(:management_token_hash)
    # One live seat per address per slot. Without it, submitting the booking
    # form from two tabs quietly consumes two seats and issues two management
    # tokens, so cancelling "the" booking only frees half of it.
    |> unique_constraint([:meeting_id, :email],
      name: :meeting_participants_live_email_index,
      message: dgettext_noop("errors", "already has a spot at this time")
    )
    |> foreign_key_constraint(:meeting_id)
    |> foreign_key_constraint(:series_id)
  end

  @doc """
  True when `changeset` failed on the one-live-seat-per-address index: the
  booker already holds a seat at this slot.
  """
  @spec duplicate_seat?(Ecto.Changeset.t()) :: boolean()
  def duplicate_seat?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      to_string(opts[:constraint_name] || "") == "meeting_participants_live_email_index"
    end)
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

  @doc "True while the seat is held for its booker to verify their email address."
  @spec unverified?(t()) :: boolean()
  def unverified?(%__MODULE__{verification_deadline_at: nil}), do: false
  def unverified?(%__MODULE__{email_verified_at: nil}), do: true
  def unverified?(%__MODULE__{}), do: false

  defp ensure_management_token(changeset) do
    case get_field(changeset, :management_token) do
      nil -> put_change(changeset, :management_token, Token.generate(@token_bytes))
      _present -> changeset
    end
  end

  @doc "An email address as a participant row stores it: trimmed and lower-cased."
  @spec normalize_email(String.t() | nil) :: String.t() | nil
  defdelegate normalize_email(email), to: BookerContact
end
