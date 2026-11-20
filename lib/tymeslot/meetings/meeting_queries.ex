defmodule Tymeslot.Meetings.MeetingQueries do
  @moduledoc """
  Database queries for Meeting schema.

  This module provides a clean interface for single-record access, writes,
  and aggregate counts on meetings. Listing, filtering, and pagination
  queries live in `Tymeslot.Meetings.MeetingListQueries`, the analytics
  aggregates in `Tymeslot.Meetings.MeetingAnalyticsQueries`, and the
  delivery bookkeeping (announcement claims, sent-email and reminder flags) in
  `Tymeslot.Meetings.MeetingDeliveryQueries`, and the guarded status
  transitions in `Tymeslot.Meetings.MeetingTransitionQueries`. Business logic
  should be handled in the `Tymeslot.Meetings` context module.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo

  @doc "Creates a meeting."
  @spec create_meeting(map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def create_meeting(attrs) when is_map(attrs) do
    %Meeting{}
    |> Meeting.changeset(attrs)
    |> Repo.insert()
  end

  @doc "Gets a single meeting by ID."
  @spec get_meeting(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting(id) do
    case UUID.cast(id) do
      {:ok, uuid} ->
        case Repo.get(Meeting, uuid) do
          nil -> {:error, :not_found}
          meeting -> {:ok, meeting}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Fetches a meeting as a webhook payload describes it: with its guests, and
  the booking page it was booked through with that page's profile.

  A webhook payload describes the meeting to an external system, and the people
  invited to it and the page it was booked through are part of that
  description, so the delivery path needs them alongside the meeting itself.
  """
  @spec get_meeting_for_webhook(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_for_webhook(id) do
    with {:ok, meeting} <- get_meeting(id) do
      {:ok, Repo.preload(meeting, [:guests, booking_page: :profile])}
    end
  end

  @doc """
  Gets a single meeting by ID and locks it for update.
  """
  @spec get_meeting_for_update(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_for_update(id) do
    case UUID.cast(id) do
      {:ok, uuid} ->
        query = from(m in Meeting, where: m.id == ^uuid, lock: "FOR UPDATE")

        case Repo.one(query) do
          nil -> {:error, :not_found}
          meeting -> {:ok, meeting}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc "Gets a single meeting by UID."
  @spec get_meeting_by_uid(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_by_uid(uid) do
    case Repo.get_by(Meeting, uid: uid) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc "The meetings carrying the invitation, newest first."
  @spec list_for_invitation(pos_integer()) :: [Meeting.t()]
  def list_for_invitation(invitation_id) do
    Meeting
    |> where([m], m.invitation_id == ^invitation_id)
    |> order_by([m], desc: m.inserted_at, desc: m.id)
    |> Repo.all()
  end

  @doc "The username the organiser of `uid` has now, if any and not pending deletion."
  @spec organizer_username_by_uid(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def organizer_username_by_uid(uid) when is_binary(uid) do
    query =
      from(m in Meeting,
        join: p in ProfileSchema,
        on: p.user_id == m.organizer_user_id,
        join: u in assoc(p, :user),
        where: m.uid == ^uid and p.username != "" and is_nil(u.deletion_scheduled_at),
        select: p.username
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      username -> {:ok, username}
    end
  end

  @doc """
  Fetches a meeting by UID only if the given `organizer_user_id` owns it.

  Returns `{:ok, meeting}` when a matching meeting is found.
  Returns `{:error, :not_found}` when no meeting exists with that UID, or when
  the meeting exists but belongs to a different organizer, or is one the
  organiser may not see (`MeetingState.visible_to_organiser?/1`, an
  unverified or unpaid hold). For the host's own lookups; the attendee's
  manage links use `get_meeting_by_uid_for_attendee/2`, and system callers
  that must reach such a meeting use `get_meeting/1`.
  """
  @spec get_meeting_by_uid_for_organizer(String.t(), integer()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_by_uid_for_organizer(uid, organizer_user_id)
      when is_integer(organizer_user_id) do
    uid
    |> by_uid_for_organizer(organizer_user_id)
    |> MeetingState.where_visible_to_organiser()
    |> one_or_not_found()
  end

  @doc """
  Fetches a meeting by UID for whoever holds its manage link (the attendee),
  scoped to the organiser whose booking page the link was opened on.

  Unlike `get_meeting_by_uid_for_organizer/2` it also finds the holds the
  organiser may not see (unverified or unpaid): the attendee made them, and
  their manage pages answer with `Tymeslot.Bookings.Policy`'s refusal rather
  than pretending the booking does not exist.
  `{:error, :not_found}` when no meeting with that UID belongs to the organiser.
  """
  @spec get_meeting_by_uid_for_attendee(String.t(), integer()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_by_uid_for_attendee(uid, organizer_user_id)
      when is_integer(organizer_user_id) do
    uid
    |> by_uid_for_organizer(organizer_user_id)
    |> one_or_not_found()
  end

  defp by_uid_for_organizer(uid, organizer_user_id),
    do: from(m in Meeting, where: m.uid == ^uid and m.organizer_user_id == ^organizer_user_id)

  defp one_or_not_found(query) do
    case Repo.one(query) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Fetches a meeting by ID only if the given `organizer_user_id` owns it.

  Returns `{:ok, meeting}` when a matching meeting is found.
  Returns `{:error, :not_found}` when no meeting exists with that ID, or when
  the meeting exists but belongs to a different organizer, or is one the
  organiser may not see (`MeetingState.visible_to_organiser?/1`, an
  unverified or unpaid hold). System callers that must reach such a meeting
  use `get_meeting/1`.
  """
  @spec get_meeting_for_organizer(String.t(), integer()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_for_organizer(id, organizer_user_id) when is_integer(organizer_user_id) do
    case UUID.cast(id) do
      {:ok, uuid} ->
        query =
          MeetingState.where_visible_to_organiser(
            from(m in Meeting, where: m.id == ^uuid and m.organizer_user_id == ^organizer_user_id)
          )

        case Repo.one(query) do
          nil -> {:error, :not_found}
          meeting -> {:ok, meeting}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Like `get_meeting_for_organizer/2`, but takes a row lock (`FOR UPDATE`) on
  the meeting. Must be called inside a transaction; it serialises writers that
  read something about the meeting (its guest count, say) before changing it.
  """
  @spec lock_meeting_for_organizer(String.t(), integer()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def lock_meeting_for_organizer(id, organizer_user_id) when is_integer(organizer_user_id) do
    case UUID.cast(id) do
      {:ok, uuid} ->
        query =
          MeetingState.where_visible_to_organiser(
            from(m in Meeting,
              where: m.id == ^uuid and m.organizer_user_id == ^organizer_user_id,
              lock: "FOR UPDATE"
            )
          )

        case Repo.one(query) do
          nil -> {:error, :not_found}
          meeting -> {:ok, meeting}
        end

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Held requests whose deadline has passed, oldest first.

  Backs the expiry sweep, which exists because a per-meeting scheduled job can
  be lost to Oban pruning, a failed insert, or a deploy that straddles the
  deadline. Ordering is oldest-first so the invitee kept waiting longest is
  released first when a backlog is being worked through.
  """
  @spec list_expired_approval_requests(DateTime.t(), pos_integer()) :: [Meeting.t()]
  def list_expired_approval_requests(%DateTime{} = now, limit) when is_integer(limit) do
    Meeting
    |> MeetingState.where_awaiting_approval()
    |> where([m], not is_nil(m.approval_deadline_at) and m.approval_deadline_at <= ^now)
    |> order_by([m], asc: m.approval_deadline_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Meetings whose reschedule request has lapsed unanswered at `now` but which
  have not been expired yet, oldest request first, at most `limit`. Backs the
  reschedule request sweep.
  """
  @spec list_lapsed_reschedule_requests(DateTime.t(), pos_integer()) :: [Meeting.t()]
  def list_lapsed_reschedule_requests(%DateTime{} = now, limit) when is_integer(limit) do
    Meeting
    |> MeetingState.where_reschedule_request_lapsed(now)
    |> order_by([m], asc: m.reschedule_requested_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Held-for-verification meetings whose verification deadline has passed at
  `now`, oldest deadline first, at most `limit`. Backs the expiry sweep.
  """
  @spec list_expired_verifications(DateTime.t(), pos_integer()) :: [Meeting.t()]
  def list_expired_verifications(%DateTime{} = now, limit) when is_integer(limit) do
    Meeting
    |> MeetingState.where_awaiting_verification()
    |> where([m], not is_nil(m.verification_deadline_at) and m.verification_deadline_at <= ^now)
    |> order_by([m], asc: m.verification_deadline_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Deletes meetings that left the verification gate without being verified
  (released statuses, a verification deadline, no `email_verified_at`) whose
  deadline is before `cutoff`. Guests cascade.

  A booking verified and expired or cancelled later has `email_verified_at`
  set and is never touched: those are the organiser's history.
  """
  @spec delete_unverified_lapsed_before(DateTime.t()) :: {non_neg_integer(), nil}
  def delete_unverified_lapsed_before(%DateTime{} = cutoff) do
    released = MeetingState.released()

    Meeting
    |> where(
      [m],
      m.status in ^released and not is_nil(m.verification_deadline_at) and
        is_nil(m.email_verified_at) and m.verification_deadline_at < ^cutoff
    )
    |> Repo.delete_all()
  end

  @doc "Updates a meeting."
  @spec update_meeting(Meeting.t(), map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def update_meeting(%Meeting{} = meeting, attrs) when is_map(attrs) do
    meeting
    |> Meeting.changeset(attrs)
    |> Repo.update()
  end

  # What a booking keeps of a room that is gone: nothing.
  @cleared_room %{
    video_room_id: nil,
    video_room_enabled: false,
    organizer_video_url: nil,
    attendee_video_url: nil
  }

  @doc """
  Clears a meeting's video room (its id and join links), writing nothing else.

  Narrower than `update_meeting/2` for the same reason as
  `update_meeting_status/2`. Rooms are cleared by system jobs (the video sync
  sweep, an integration's disconnect) on meetings of any age, including a
  one-to-one meeting whose invitee data was erased (`Tymeslot.InviteeData`),
  which no longer carries the attendee fields `Meeting.changeset/2` demands.
  Through that changeset the clear would fail and leave a dead room id that
  the scans keep finding.
  """
  @spec clear_video_room(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def clear_video_room(%Meeting{} = meeting) do
    meeting
    |> Changeset.change(@cleared_room)
    |> Repo.update()
  end

  @doc """
  Updates a meeting's status transition fields only (`status`,
  `cancelled_at`, `cancellation_reason`, `approval_requested_at`,
  `approval_deadline_at`).

  Used by cancellation, expiry and payment-confirmation flows instead of
  `update_meeting/2`: those touch only these fields, and group meetings
  legitimately carry no `attendee_name`/`attendee_email` (nor do some
  older solo rows), fields `Meeting.changeset/2` would otherwise demand.
  """
  @spec update_meeting_status(Meeting.t(), map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def update_meeting_status(%Meeting{} = meeting, attrs) when is_map(attrs) do
    meeting
    |> Meeting.status_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Records that the host has been nudged about an unanswered request.

  The durable half of the nudge's idempotency: the Oban unique key stops a
  second job being enqueued, this stops a retry of the same job sending a
  second copy after the first send succeeded but the job then failed.
  """
  @spec mark_approval_nudge_sent(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def mark_approval_nudge_sent(%Meeting{} = meeting) do
    meeting
    |> Changeset.change(approval_nudge_sent_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  @doc """
  Counts the meetings holding a provider room created by the given integration,
  within `scope`.

  Drives the room cleanup line in the disconnect modal, so the user knows what
  the optional cleanup would affect before choosing it. Built on the same query
  the disconnect drains (`MeetingListQueries.with_video_room_for_integration/3`),
  so the two cannot disagree.
  """
  @spec count_with_video_room_for_integration(
          pos_integer(),
          MeetingListQueries.room_scope(),
          DateTime.t()
        ) :: non_neg_integer()
  def count_with_video_room_for_integration(integration_id, scope, %DateTime{} = now) do
    integration_id
    |> MeetingListQueries.with_video_room_for_integration(scope, now)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Lists the start times (and meeting type) of an organizer's slot-occupying
  bookings whose `start_time` falls in `[from_utc, to_utc)`.

  Counts only meetings that hold a slot (`MeetingState.where_slot_live/1`), so
  cancelled, completed and expired bookings are excluded. Used by the booking
  limits feature to bucket bookings into host-timezone periods.

  Nothing writes the `:completed` status, so a booking that has already
  happened is still `:confirmed` and still counts towards its period's cap.
  That is what the caps are meant to measure — a day's load, not what is left
  of it — but it does mean the exclusion above is latent, not observed.

  A session the host planned on a fixed-date type
  (`Tymeslot.Meetings.PlannedSessions`) is a row before anyone books it, so
  it counts only once someone holds a seat on it, and then once, however
  many seats are taken: a group slot occupies one booking of the cap, as a
  slot a first booker created does.

  Options:
    * `:exclude_uid` — omit one meeting by UID (self-exclusion on reschedule).
  """
  @spec list_live_booking_starts(integer(), DateTime.t(), DateTime.t(), keyword()) :: [
          %{start_time: DateTime.t(), meeting_type_id: integer() | nil}
        ]
  def list_live_booking_starts(
        organizer_user_id,
        %DateTime{} = from_utc,
        %DateTime{} = to_utc,
        opts
      ) do
    query =
      from(m in Meeting, as: :meeting)
      |> MeetingState.where_slot_live()
      |> where([m], m.organizer_user_id == ^organizer_user_id)
      |> where([m], m.start_time >= ^from_utc and m.start_time < ^to_utc)
      |> where(
        [meeting: m],
        not m.planned or
          exists(
            from(p in ParticipantSchema,
              where: p.meeting_id == parent_as(:meeting).id and is_nil(p.cancelled_at),
              select: 1
            )
          )
      )
      |> select([m], %{start_time: m.start_time, meeting_type_id: m.meeting_type_id})

    query =
      case Keyword.get(opts, :exclude_uid) do
        nil -> query
        uid -> where(query, [m], m.uid != ^uid)
      end

    Repo.all(query)
  end

  @doc """
  How many booking requests this host has not yet answered.

  Drives the dashboard's count badge, and is backed by the partial index
  `meetings_pending_approval_by_organizer` so it stays a cheap query on a
  dashboard that renders it on every load.

  The sessions of a booking series held for approval are one request, and
  count once: requests are counted by series, a meeting outside any series
  by itself.
  """
  @spec count_awaiting_approval_for_organizer(integer()) :: non_neg_integer()
  def count_awaiting_approval_for_organizer(organizer_user_id) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> MeetingState.where_awaiting_approval()
    |> select([m], count(coalesce(m.series_id, m.id), :distinct))
    |> Repo.one()
  end

  @doc """
  Returns the count of meetings with status `awaiting_payment` for a given organizer.

  Used by `Tymeslot.MeetingPayments` to guard currency changes: if the host has any
  meetings waiting for payment, the currency cannot be changed until they are resolved.
  """
  @spec count_awaiting_payment_for_organizer(integer()) :: non_neg_integer()
  def count_awaiting_payment_for_organizer(organizer_user_id) do
    Repo.aggregate(
      from(m in Meeting,
        where: m.organizer_user_id == ^organizer_user_id and m.status == :awaiting_payment
      ),
      :count,
      :id
    )
  end
end
