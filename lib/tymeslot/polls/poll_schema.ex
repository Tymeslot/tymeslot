defmodule Tymeslot.Polls.PollSchema do
  @moduledoc "A meeting poll: proposed candidate slots that invitees vote on."

  use Ecto.Schema

  import Ecto.Changeset

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Bookings.CreateAdHoc
  alias Tymeslot.Clock
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.Reminders
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.Polls.{PollParticipantSchema, PollTimeSlotSchema}
  alias Tymeslot.Security.EncryptedString
  alias Tymeslot.Security.Token
  alias Tymeslot.Validation.Constraints
  alias Tymeslot.Venues.VenueSchema

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
    # hashed; it is looked up by `token_hash`.
    field(:token, EncryptedString, source: :token_encrypted, redact: true)
    field(:token_hash, :string)
    # A `:draft` is the host's alone until they publish it: its link does not
    # resolve (`PollQueries.get_by_token/1`), nobody is invited or emailed, and
    # it is not among the open polls a username change would strand.
    field(:status, Ecto.Enum, values: [:draft, :open, :confirmed, :cancelled], default: :open)
    # The people a draft will invite, as `Tymeslot.Polls.Invitations.entry/0`
    # maps, held until it is published (see `draft_invitees/1`). Nil once it
    # is, and on every poll created published.
    field(:draft_invitees, {:array, :map})
    # Whether the host is emailed about new votes, bundled per quarter hour
    # (`Tymeslot.Emails.EmailScheduler.schedule_poll_vote_digest/1`),
    # and when they last were, so the next update names only who voted since.
    field(:notify_on_vote, :boolean, default: false)
    # Whether only the people the host invited by email can vote. When set,
    # the shared link asks nobody for their address
    # (`Tymeslot.Polls.Voting.request_link/2` refuses), and switching it on
    # withdraws the requests already waiting (`Tymeslot.Polls.Editing`).
    field(:invite_only, :boolean, default: false)
    # When participants who have not voted are reminded, as lead times before
    # `deadline_at`. Nil for a poll from before the host could choose: see
    # `reminders/1`.
    field(:reminder_config, {:array, :map})
    field(:vote_digest_sent_at, :utc_datetime)
    field(:deadline_at, :utc_datetime)
    field(:timezone, :string)
    field(:confirmed_at, :utc_datetime)
    # Where the meeting will be held, as the host chose it for this poll: a
    # video call on `video_integration`, the saved `venue`, or the place in
    # `location_details`. None leaves it to the meeting type, if the poll
    # has one (`Tymeslot.Polls.PollLocation`).
    field(:location_kind, Ecto.Enum, values: [:video, :in_person, :custom])
    field(:location_details, :string)

    belongs_to(:user, UserSchema, type: :id)
    belongs_to(:meeting_type, MeetingTypeSchema, type: :id)
    belongs_to(:venue, VenueSchema, type: :id)
    belongs_to(:video_integration, VideoIntegrationSchema, type: :id)
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

  @location_fields [:location_kind, :location_details, :venue_id, :video_integration_id]

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
      :invite_only,
      :reminder_config,
      :draft_invitees
      | @location_fields
    ])
    |> validate_required([:user_id, :title, :duration_minutes, :timezone])
    |> validate_number(:duration_minutes, Constraints.poll_duration_minutes_opts())
    |> validate_length(:title, max: 255)
    |> validate_description_length()
    |> validate_reminder_config()
    |> validate_future_deadline()
    |> validate_location()
    |> put_new_token()
    |> Token.put_hash(:token, :token_hash)
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:meeting_type_id)
    |> location_constraints()
  end

  @doc """
  Changeset for a host editing an open poll.

  Covers the title, the description, whether the host is told about new votes,
  who can vote (`invite_only`), the voting deadline, the reminders before it,
  the meeting type whose calendar the confirmed meeting uses, and where it is
  held (both checked by `Tymeslot.Polls.Editing`, which knows the host). A
  location left out of `attrs` stays as it is. A deadline may
  be moved, removed, or set again after it passed, which reopens voting, but
  never into the past. The candidate times, duration and timezone stay as they are:
  guests voted against the slots they were shown, so changing those under an
  in-flight poll would silently invalidate votes already cast. Times can only
  be added (`Tymeslot.Polls.Editing`).
  """
  @spec details_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def details_changeset(poll, attrs) do
    poll
    |> cast(attrs, [
      :title,
      :description,
      :notify_on_vote,
      :invite_only,
      :deadline_at,
      :reminder_config,
      :meeting_type_id
      | @location_fields
    ])
    |> start_updates_from_now()
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
    |> validate_location()
    |> foreign_key_constraint(:meeting_type_id)
    |> location_constraints()
  end

  @doc """
  Whether voting is open at `now`: open status and no deadline, or a deadline
  still ahead of `now`.
  """
  @spec voting_open?(%__MODULE__{} | map(), DateTime.t()) :: boolean()
  def voting_open?(poll, now \\ Clock.utc_now())
  def voting_open?(%{status: status}, _now) when status != :open, do: false
  def voting_open?(%{deadline_at: nil}, _now), do: true

  def voting_open?(%{deadline_at: deadline_at}, now) do
    DateTime.compare(now, deadline_at) == :lt
  end

  @doc """
  Of `polls`, the one whose voting closes next after `now`: the earliest
  deadline among those still open to votes. Nil when none of them has a
  deadline still ahead.
  """
  @spec next_to_close([%__MODULE__{}], DateTime.t()) :: %__MODULE__{} | nil
  def next_to_close(polls, now) do
    polls
    |> Enum.filter(&(&1.deadline_at && voting_open?(&1, now)))
    |> Enum.min_by(& &1.deadline_at, DateTime, fn -> nil end)
  end

  @doc """
  The poll's reminders as `%{value:, unit:}` lead times before its deadline.
  A poll from before the host could choose them keeps the one reminder every
  poll had then, a day before.
  """
  @spec reminders(%__MODULE__{}) :: [%{value: pos_integer(), unit: String.t()}]
  def reminders(%__MODULE__{reminder_config: nil}), do: [%{value: 1, unit: "days"}]

  def reminders(%__MODULE__{reminder_config: config}),
    do: Reminders.normalize_reminders(config)

  # Only a deadline being set is judged: an untouched one that has passed must
  # not stop the host fixing a typo in the title.
  defp validate_future_deadline(changeset) do
    validate_change(changeset, :deadline_at, fn :deadline_at, deadline_at ->
      if future?(deadline_at), do: [], else: [deadline_at: "must be in the future"]
    end)
  end

  # Whatever the deadline was when it was set.
  defp validate_deadline_ahead(changeset) do
    case get_field(changeset, :deadline_at) do
      nil ->
        changeset

      deadline_at ->
        if future?(deadline_at),
          do: changeset,
          else: add_error(changeset, :deadline_at, "must be in the future")
    end
  end

  defp future?(deadline_at), do: DateTime.compare(deadline_at, DateTime.utc_now()) == :gt

  # Turning updates on starts them from now: a vote cast before is not news
  # the host asked to hear, however long ago the last update went out.
  defp start_updates_from_now(changeset) do
    case get_change(changeset, :notify_on_vote) do
      true ->
        put_change(changeset, :vote_digest_sent_at, DateTime.truncate(Clock.utc_now(), :second))

      _unchanged_or_off ->
        changeset
    end
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

  # Each kind keeps the one field that says where, and the others are
  # cleared, so a poll switched from a venue to a video call does not carry
  # the venue along. The host's ownership of the venue or integration is
  # checked by the context, which knows the host (`PollLocation.check/2`).
  defp validate_location(changeset) do
    if Enum.any?(@location_fields, &Map.has_key?(changeset.changes, &1)),
      do: settle_location(changeset, get_field(changeset, :location_kind)),
      else: changeset
  end

  defp settle_location(changeset, nil), do: clear_location(changeset, @location_fields)

  defp settle_location(changeset, :video) do
    changeset
    |> clear_location([:location_details, :venue_id])
    |> validate_required([:video_integration_id])
  end

  defp settle_location(changeset, :in_person) do
    changeset
    |> clear_location([:location_details, :video_integration_id])
    |> validate_required([:venue_id])
  end

  defp settle_location(changeset, :custom) do
    changeset
    |> clear_location([:venue_id, :video_integration_id])
    |> update_change(:location_details, &trim_to_nil/1)
    |> validate_required([:location_details])
    |> validate_length(:location_details, max: CreateAdHoc.custom_location_max_length())
  end

  defp clear_location(changeset, fields),
    do: Enum.reduce(fields, changeset, &put_change(&2, &1, nil))

  defp location_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:video_integration_id)
    |> check_constraint(:location_kind, name: :polls_location_kind_must_be_known)
  end

  # The description becomes the confirmed meeting's organiser note, so it is
  # held to that limit from the start.
  defp validate_description_length(changeset),
    do: validate_length(changeset, :description, max: MeetingSchema.organizer_note_max_length())

  @doc """
  Changeset publishing a draft: it opens for votes, and the invitees it held
  leave it, to be invited as participants in the same transaction.

  The deadline is judged here, against the moment of publication: one set
  while drafting may have passed since, and a poll must not go out closed.
  """
  @spec publish_changeset(%__MODULE__{status: :draft}) :: Ecto.Changeset.t()
  def publish_changeset(%__MODULE__{status: :draft} = poll) do
    poll
    |> change(status: :open, draft_invitees: nil)
    |> validate_deadline_ahead()
  end

  @doc """
  The invitees a draft holds, as `Tymeslot.Polls.Invitations.entry/0` maps.
  Empty for a poll that is not a draft.
  """
  @spec draft_invitees(%__MODULE__{}) :: [%{email: String.t(), name: String.t() | nil}]
  def draft_invitees(%__MODULE__{draft_invitees: nil}), do: []

  def draft_invitees(%__MODULE__{draft_invitees: invitees}) do
    for invitee <- invitees,
        do: %{email: entry_value(invitee, :email), name: entry_value(invitee, :name)}
  end

  # Read back from the database the keys are strings; on a struct not yet
  # saved they are still the atoms they were written with.
  defp entry_value(invitee, key), do: Map.get(invitee, key, invitee[Atom.to_string(key)])

  @spec confirm_changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def confirm_changeset(poll, attrs) do
    poll
    |> cast(attrs, [:status, :confirmed_meeting_id, :confirmed_at])
    |> validate_required([:status, :confirmed_meeting_id, :confirmed_at])
  end

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
      nil -> put_change(changeset, :token, Token.generate(24))
      _token -> changeset
    end
  end
end
