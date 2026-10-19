defmodule Tymeslot.Meetings.MeetingQueries do
  @moduledoc """
  Database queries for Meeting schema.

  This module provides a clean interface for single-record access, writes,
  and aggregate counts on meetings. Listing, filtering, and pagination
  queries live in `Tymeslot.Meetings.MeetingListQueries`, the analytics
  aggregates in `Tymeslot.Meetings.MeetingAnalyticsQueries`, and the
  delivery bookkeeping (announcement claims, sent-email and reminder flags) in
  `Tymeslot.Meetings.MeetingDeliveryQueries`. Business logic
  should be handled in the `Tymeslot.Meetings` context module.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingListQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
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
  Fetches a meeting with its guests loaded.

  A webhook payload describes the meeting to an external system, and the people
  invited to it are part of that description, so the delivery path needs them
  alongside the meeting itself.
  """
  @spec get_meeting_with_guests(String.t()) :: {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_with_guests(id) do
    with {:ok, meeting} <- get_meeting(id) do
      {:ok, Repo.preload(meeting, :guests)}
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
  the meeting exists but belongs to a different organizer.
  """
  @spec get_meeting_by_uid_for_organizer(String.t(), integer()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_by_uid_for_organizer(uid, organizer_user_id)
      when is_integer(organizer_user_id) do
    query =
      from(m in Meeting,
        where: m.uid == ^uid and m.organizer_user_id == ^organizer_user_id
      )

    case Repo.one(query) do
      nil -> {:error, :not_found}
      meeting -> {:ok, meeting}
    end
  end

  @doc """
  Fetches a meeting by ID only if the given `organizer_user_id` owns it.

  Returns `{:ok, meeting}` when a matching meeting is found.
  Returns `{:error, :not_found}` when no meeting exists with that ID, or when
  the meeting exists but belongs to a different organizer.
  """
  @spec get_meeting_for_organizer(String.t(), integer()) ::
          {:ok, Meeting.t()} | {:error, :not_found}
  def get_meeting_for_organizer(id, organizer_user_id) when is_integer(organizer_user_id) do
    case UUID.cast(id) do
      {:ok, uuid} ->
        query =
          from(m in Meeting,
            where: m.id == ^uuid and m.organizer_user_id == ^organizer_user_id
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
          from(m in Meeting,
            where: m.id == ^uuid and m.organizer_user_id == ^organizer_user_id,
            lock: "FOR UPDATE"
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
  Moves a meeting out of `"awaiting_approval"`, atomically.

  The guard is in the `WHERE` clause rather than read-then-write, because
  every exit from the approval gate races every other one: the host can
  approve in the dashboard while the expiry job fires, or click Approve twice,
  or decline from an email link a colleague already actioned. A changeset
  update would let the second writer silently overwrite the first, producing a
  confirmed meeting the host declined.

  Exactly one caller wins and receives the updated meeting; every other gets
  `{:error, :not_awaiting_approval}` and can say "already answered" rather
  than acting twice. `Tymeslot.Meetings.Approval` is the only intended caller.

  Bypasses the changeset deliberately — `update_all` takes plain columns — so
  `updated_at` is set here rather than by `timestamps/1`. Because there is no
  changeset, a violation of `unique_confirmed_meeting_per_organizer_at_time`
  (the guarantee that at most one confirmed-or-held meeting occupies an
  organizer's slot — widened to cover held requests by
  `20260902120100_add_unique_index_to_held_meetings.exs`) has no
  `unique_constraint/3` to translate it, so it is caught here directly and
  turned into `{:error, :slot_taken}` rather than letting the raw
  `Postgrex.Error` reach the caller.
  """
  @spec transition_from_awaiting_approval(String.t(), keyword()) ::
          {:ok, Meeting.t()} | {:error, :not_awaiting_approval | :slot_taken}
  def transition_from_awaiting_approval(meeting_id, changes) when is_list(changes) do
    now = DateTime.utc_now(:second)

    query =
      from(m in Meeting,
        where: m.id == ^meeting_id and m.status == "awaiting_approval",
        select: m
      )

    case Repo.update_all(query, set: Keyword.put_new(changes, :updated_at, now)) do
      {1, [meeting]} -> {:ok, meeting}
      {0, _none} -> {:error, :not_awaiting_approval}
    end
  rescue
    error in Postgrex.Error ->
      case error.postgres do
        %{code: :unique_violation, constraint: "unique_confirmed_meeting_per_organizer_at_time"} ->
          {:error, :slot_taken}

        _other ->
          reraise error, __STACKTRACE__
      end
  end

  @doc """
  Moves a meeting to `"cancelled"`, atomically, unless it is already over.

  Like `transition_from_awaiting_approval/2`, the guard is in the `WHERE`
  clause rather than read-then-write: a guest cancelling from the email link,
  the host cancelling from the dashboard and the external-deletion sync can
  all act on the same meeting at once, each holding a copy read before the
  others wrote. Exactly one of them changes the row and receives it; every
  other gets `{:error, :already_cancelled}` and must not repeat the
  cancellation's side effects. A meeting that completed or expired in the
  meantime refuses the same way, since there is nothing left to cancel.

  `changes` carries `cancelled_at` and, where there is one,
  `cancellation_reason`; `status` is always set here. Bypasses the changeset,
  as `update_all` does, so `updated_at` is set here too.
  """
  @spec transition_to_cancelled(String.t(), keyword()) ::
          {:ok, Meeting.t()} | {:error, :already_cancelled}
  def transition_to_cancelled(meeting_id, changes) when is_list(changes) do
    now = DateTime.utc_now(:second)

    query =
      MeetingState.where_not_terminal(from(m in Meeting, where: m.id == ^meeting_id, select: m))

    changes =
      changes
      |> Keyword.put(:status, "cancelled")
      |> Keyword.put_new(:updated_at, now)

    case Repo.update_all(query, set: changes) do
      {1, [meeting]} -> {:ok, meeting}
      {0, _none} -> {:error, :already_cancelled}
    end
  end

  @doc """
  Stamps `reschedule_requested_at` on a meeting, atomically, unless a
  request is already pending, the meeting still awaits the host's approval,
  it has started by `requested_at`, or it is already over: the same rule
  `Tymeslot.Bookings.Policy.can_request_reschedule?/1` applies, held by the
  row as it stands rather than by the caller's copy.

  The guard is in the `WHERE` clause for the same reason as
  `transition_to_cancelled/2`: two requests for one meeting (a double click,
  two tabs, a retried request) each hold a copy read before the other wrote,
  so a check on that copy lets both through. Exactly one changes the row and
  receives it; the other gets `{:error, :not_requestable}` and must not
  queue a second email. Bypasses the changeset, so `updated_at` is set here.
  """
  @spec mark_reschedule_requested(String.t(), DateTime.t()) ::
          {:ok, Meeting.t()} | {:error, :not_requestable}
  def mark_reschedule_requested(meeting_id, %DateTime{} = requested_at) do
    query =
      from(m in Meeting,
        where:
          m.id == ^meeting_id and is_nil(m.reschedule_requested_at) and
            m.start_time > ^requested_at,
        select: m
      )
      |> MeetingState.where_not_terminal()
      |> MeetingState.where_not_awaiting_approval()

    case Repo.update_all(query,
           set: [reschedule_requested_at: requested_at, updated_at: DateTime.utc_now(:second)]
         ) do
      {1, [meeting]} -> {:ok, meeting}
      {0, _none} -> {:error, :not_requestable}
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

  @doc "Updates a meeting."
  @spec update_meeting(Meeting.t(), map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def update_meeting(%Meeting{} = meeting, attrs) when is_map(attrs) do
    meeting
    |> Meeting.changeset(attrs)
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

  Nothing writes the `"completed"` status, so a booking that has already
  happened is still `"confirmed"` and still counts towards its period's cap.
  That is what the caps are meant to measure — a day's load, not what is left
  of it — but it does mean the exclusion above is latent, not observed.

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
      Meeting
      |> MeetingState.where_slot_live()
      |> where([m], m.organizer_user_id == ^organizer_user_id)
      |> where([m], m.start_time >= ^from_utc and m.start_time < ^to_utc)
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
  """
  @spec count_awaiting_approval_for_organizer(integer()) :: non_neg_integer()
  def count_awaiting_approval_for_organizer(organizer_user_id) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> MeetingState.where_awaiting_approval()
    |> Repo.aggregate(:count, :id)
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
        where: m.organizer_user_id == ^organizer_user_id and m.status == "awaiting_payment"
      ),
      :count,
      :id
    )
  end
end
