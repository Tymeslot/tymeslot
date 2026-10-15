defmodule Tymeslot.Polls.PollSchema do
  @moduledoc "A meeting poll: proposed candidate slots that invitees vote on."

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.Polls.{PollParticipantSchema, PollTimeSlotSchema}
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.Token
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Utils.UnguessableToken
  alias Tymeslot.Validation.Constraints

  @max_slots 40
  @max_participants 40
  # Requests for a voting link not yet confirmed, counted apart from the cap
  # above so that requests nobody confirms cannot fill a poll. Bounded too,
  # since each one stores an address and sends an email; they expire after
  # `PollParticipantSchema.unconfirmed_ttl_seconds/0`.
  @max_unconfirmed_participants 100

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "polls" do
    field(:title, :string)
    field(:description, :string)
    field(:duration_minutes, :integer)
    # The poll's public voting link, which the host copies from the
    # dashboard again whenever they like, so it is encrypted rather than only
    # hashed; it is looked up by `token_hash`. The plain `token` column
    # predates this and is no longer read or written.
    field(:token, EncryptedString, source: :token_encrypted, redact: true)
    field(:token_hash, :string)
    field(:status, Ecto.Enum, values: [:open, :confirmed, :cancelled], default: :open)
    # Whether the host is emailed about new votes, bundled per quarter hour
    # (`Tymeslot.Emails.EmailScheduler.PollScheduler.schedule_vote_digest/1`),
    # and when they last were, so the next update names only who voted since.
    field(:notify_on_vote, :boolean, default: false)
    # When participants who have not voted are reminded, as lead times before
    # `deadline_at`. Nil for a poll from before the host could choose: see
    # `reminders/1`.
    field(:reminder_config, {:array, :map})
    field(:vote_digest_sent_at, :utc_datetime)
    field(:deadline_at, :utc_datetime)
    field(:timezone, :string)
    field(:confirmed_at, :utc_datetime)

    belongs_to(:user, UserSchema, type: :id)
    belongs_to(:meeting_type, MeetingTypeSchema, type: :id)
    belongs_to(:confirmed_meeting, MeetingSchema, type: :binary_id)

    has_many(:time_slots, PollTimeSlotSchema,
      foreign_key: :poll_id,
      preload_order: [asc: :position]
    )

    # `:email` breaks the tie rather than `:id`, which is a v4 UUID and so
    # orders randomly. `inserted_at` alone is not a total order here: the
    # timestamps are second-precision, and two strangers following the same
    # poll link land in the same second often enough that the arbitrary winner
    # reached `Confirm.pick_primary/2`, which promotes the first available
    # voter to primary attendee.
    #
    # Only confirmed participants: someone who asked for a link but never
    # saved responses through it has proved nothing about their address, so
    # they stay out of the tallies, the results and the confirmed meeting.
    has_many(:participants, PollParticipantSchema,
      foreign_key: :poll_id,
      where: [confirmed_at: {:not, nil}],
      preload_order: [asc: :inserted_at, asc: :email]
    )

    timestamps(type: :utc_datetime)
  end

  @spec max_slots() :: pos_integer()
  def max_slots, do: @max_slots

  @spec max_participants() :: pos_integer()
  def max_participants, do: @max_participants

  @spec max_unconfirmed_participants() :: pos_integer()
  def max_unconfirmed_participants, do: @max_unconfirmed_participants

  @spec creation_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def creation_changeset(poll, attrs) do
    poll
    |> cast(attrs, [
      :user_id,
      :meeting_type_id,
      :title,
      :description,
      :duration_minutes,
      :deadline_at,
      :timezone,
      :notify_on_vote,
      :reminder_config
    ])
    |> validate_required([:user_id, :title, :duration_minutes, :timezone])
    |> validate_number(:duration_minutes, Constraints.poll_duration_minutes_opts())
    |> validate_length(:title, max: 255)
    |> validate_description_length()
    |> validate_reminder_config()
    |> put_new_token()
    |> Token.put_hash(:token, :token_hash)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:meeting_type_id)
  end

  @doc """
  Changeset for a host editing an open poll.

  Covers the title, the description, whether the host is told about new votes,
  the voting deadline and the reminders before it. A deadline may be moved,
  removed, or set again after it passed, which reopens voting, but never into
  the past. The candidate times, duration and timezone stay as they are:
  guests voted against the slots they were shown, so changing those under an
  in-flight poll would silently invalidate votes already cast. Times can only
  be added (`Tymeslot.Polls.Editing`).
  """
  @spec details_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def details_changeset(poll, attrs) do
    poll
    |> cast(attrs, [:title, :description, :notify_on_vote, :deadline_at, :reminder_config])
    # `cast/3` already nils a whitespace-only string, so these have to tolerate
    # nil as well as trim: a title of "   " arrives here as a nil *change*, and
    # `validate_required/2` is what turns it into an error.
    |> update_change(:title, &trim_to_nil/1)
    |> update_change(:description, &trim_to_nil/1)
    |> validate_required([:title])
    |> validate_length(:title, max: 255)
    |> validate_description_length()
    |> validate_future_deadline()
    |> validate_reminder_config()
  end

  @doc """
  The poll's reminders as `%{value:, unit:}` lead times before its deadline.
  A poll from before the host could choose them keeps the one reminder every
  poll had then, a day before.
  """
  @spec reminders(%__MODULE__{}) :: [%{value: pos_integer(), unit: String.t()}]
  def reminders(%__MODULE__{reminder_config: nil}), do: [%{value: 1, unit: "days"}]

  def reminders(%__MODULE__{reminder_config: config}),
    do: ReminderUtils.normalize_reminders(config)

  # Only a deadline being set is judged: an untouched one that has passed must
  # not stop the host fixing a typo in the title.
  defp validate_future_deadline(changeset) do
    validate_change(changeset, :deadline_at, fn :deadline_at, deadline_at ->
      if DateTime.compare(deadline_at, DateTime.utc_now()) == :gt,
        do: [],
        else: [deadline_at: "must be in the future"]
    end)
  end

  defp validate_reminder_config(changeset) do
    case get_change(changeset, :reminder_config) do
      nil -> changeset
      reminders -> check_reminders(changeset, reminders)
    end
  end

  # The same rules as a meeting type's reminders: at most three, no two alike,
  # none more than a year ahead.
  defp check_reminders(changeset, reminders) do
    with {:ok, normalised} <- ReminderValidation.parse_and_normalize_reminders(reminders),
         :ok <- ReminderValidation.validate_reminders_policy(normalised) do
      put_change(changeset, :reminder_config, Enum.map(normalised, &stringify/1))
    else
      {:error, message} -> add_error(changeset, :reminder_config, message)
    end
  end

  defp stringify(%{value: value, unit: unit}), do: %{"value" => value, "unit" => unit}

  # The description becomes the confirmed meeting's organiser note, so it is
  # held to that limit from the start.
  defp validate_description_length(changeset),
    do: validate_length(changeset, :description, max: MeetingSchema.organizer_note_max_length())

  @spec confirm_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def confirm_changeset(poll, attrs) do
    poll
    |> cast(attrs, [:status, :confirmed_meeting_id, :confirmed_at])
    |> validate_required([:status, :confirmed_meeting_id, :confirmed_at])
  end

  @doc "Marks the host as told about every vote cast up to `sent_at`."
  @spec vote_digest_sent_changeset(%__MODULE__{}, DateTime.t()) :: Ecto.Changeset.t()
  def vote_digest_sent_changeset(poll, sent_at),
    do: change(poll, vote_digest_sent_at: DateTime.truncate(sent_at, :second))

  @spec cancel_changeset(%__MODULE__{}) :: Ecto.Changeset.t()
  def cancel_changeset(poll), do: change(poll, status: :cancelled)

  defp trim_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp trim_to_nil(value), do: value

  defp put_new_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, UnguessableToken.generate())
      _token -> changeset
    end
  end
end
