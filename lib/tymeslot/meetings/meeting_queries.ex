defmodule Tymeslot.Meetings.MeetingQueries do
  @moduledoc """
  Database queries for Meeting schema.

  This module provides a clean interface for single-record access, writes,
  and aggregate counts on meetings. Listing, filtering, and pagination
  queries live in `Tymeslot.Meetings.MeetingListQueries`. Business logic
  should be handled in the `Tymeslot.Meetings` context module.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  @doc "Creates a meeting."
  @spec create_meeting(map()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def create_meeting(attrs \\ %{}) when is_map(attrs) do
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
  Writes a new attendee-notification baseline for a meeting, updating both the
  serialised `last_notified_state` snapshot and `ical_sequence` atomically.
  """
  @spec update_notification_baseline(Meeting.t(), map(), non_neg_integer()) ::
          {:ok, Meeting.t()} | {:error, Changeset.t()}
  def update_notification_baseline(%Meeting{} = meeting, state, sequence)
      when is_map(state) and is_integer(sequence) do
    meeting
    |> Changeset.change(last_notified_state: state, ical_sequence: sequence)
    |> Repo.update()
  end

  @doc "Deletes a meeting."
  @spec delete_meeting(Meeting.t()) :: {:ok, Meeting.t()} | {:error, Changeset.t()}
  def delete_meeting(%Meeting{} = meeting) do
    Repo.delete(meeting)
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
  Claims the `meeting.created` announcement for a meeting.

  Returns `:ok` to exactly one caller and `:already_announced` to every one
  after it, so an event deferred to `Tymeslot.Workers.VideoRoomWorker` cannot
  fan out a second time when a room finally arrives after recovery has already
  announced the booking without one.

  The claim is a single conditional UPDATE rather than a read followed by a
  write, so two callers racing on the same meeting cannot both win it.
  """
  @spec claim_announcement(term()) :: :ok | :already_announced
  def claim_announcement(meeting_id) do
    case UUID.cast(meeting_id) do
      {:ok, uuid} -> claim_announcement_for(uuid)
      # Nothing to dedupe against, so let the caller announce rather than
      # swallow an event on the strength of an id we cannot look up.
      :error -> :ok
    end
  end

  defp claim_announcement_for(uuid) do
    now = DateTime.utc_now(:second)

    {claimed, _rows} =
      Repo.update_all(
        from(m in Meeting,
          where: m.id == ^uuid and is_nil(m.announced_at),
          update: [
            set: [
              announced_at: ^now,
              # `announced_at` is cleared again if a reschedule sends this
              # booking back into the approval gate, so the fact that it was
              # once announced has to survive somewhere else. COALESCE keeps
              # the first stamp across any number of re-gates.
              first_announced_at: fragment("COALESCE(?, ?)", m.first_announced_at, ^now)
            ]
          ]
        ),
        []
      )

    cond do
      claimed == 1 -> :ok
      Repo.exists?(from(m in Meeting, where: m.id == ^uuid)) -> :already_announced
      # The meeting is gone, or was never persisted. Either way there is no
      # stamp to read, and refusing to announce would be the worse failure.
      true -> :ok
    end
  end

  @doc """
  Marks an email as sent for a meeting.

  ## Examples

      iex> mark_email_sent(meeting, :organizer)
      {:ok, %Meeting{}}

      iex> mark_email_sent(meeting, :attendee)
      {:ok, %Meeting{}}

      iex> mark_email_sent(meeting, :reminder)
      {:ok, %Meeting{}}

      iex> mark_email_sent(meeting, :invalid)
      {:error, :invalid_email_type}

  """
  @spec mark_email_sent(Meeting.t(), :organizer | :attendee | :reminder | atom()) ::
          {:ok, Meeting.t()} | {:error, :invalid_email_type | Changeset.t()}
  def mark_email_sent(%Meeting{} = meeting, email_type) do
    attrs =
      case email_type do
        :organizer -> %{organizer_email_sent: true}
        :attendee -> %{attendee_email_sent: true}
        :reminder -> %{reminder_email_sent: true}
        _other -> nil
      end

    if attrs do
      update_meeting(meeting, attrs)
    else
      {:error, :invalid_email_type}
    end
  end

  @doc """
  Records per-recipient reminder delivery for one `(value, unit)` reminder
  config, upserting rather than appending: an existing entry for that config
  has its `organizer_sent`/`attendee_sent` flags OR-merged with the new
  result, so a later send to the still-unsent recipient doesn't clobber an
  earlier success. A config with no existing entry gets one appended.

  Entries written before per-recipient tracking existed carry only `value`
  and `unit`. They are treated as already fully sent (both flags default to
  `true`) so old data can never trigger a fresh send.

  Locks the row for the read-merge-write to stay correct under concurrent
  workers for the same meeting.
  """
  @spec upsert_reminder_sent(Meeting.t(), %{
          :value => integer(),
          :unit => String.t(),
          optional(:organizer_sent) => boolean(),
          optional(:attendee_sent) => boolean()
        }) :: {:ok, Meeting.t()} | {:error, :not_found | Changeset.t()}
  def upsert_reminder_sent(%Meeting{} = meeting, %{value: val, unit: unit} = attrs) do
    organizer_sent = Map.get(attrs, :organizer_sent, false)
    attendee_sent = Map.get(attrs, :attendee_sent, false)

    Repo.transaction(fn ->
      case get_meeting_for_update(meeting.id) do
        {:ok, locked_meeting} ->
          updated_list =
            merge_reminder_sent(
              locked_meeting.reminders_sent,
              val,
              unit,
              organizer_sent,
              attendee_sent
            )

          case update_meeting(locked_meeting, %{
                 reminder_email_sent: true,
                 reminders_sent: updated_list
               }) do
            {:ok, updated_meeting} -> updated_meeting
            {:error, changeset} -> Repo.rollback(changeset)
          end

        {:error, :not_found} ->
          Repo.rollback(:not_found)
      end
    end)
  end

  defp merge_reminder_sent(existing, val, unit, organizer_sent, attendee_sent) do
    entries = List.wrap(existing)

    {updated_entries, found?} =
      Enum.map_reduce(entries, false, fn entry, found? ->
        if reminder_entry_match?(entry, val, unit) do
          {merge_reminder_entry(entry, val, unit, organizer_sent, attendee_sent), true}
        else
          {entry, found?}
        end
      end)

    if found? do
      updated_entries
    else
      updated_entries ++
        [
          %{
            "value" => val,
            "unit" => unit,
            "organizer_sent" => organizer_sent,
            "attendee_sent" => attendee_sent
          }
        ]
    end
  end

  @doc """
  Whether a `reminders_sent` entry matches the given `(value, unit)` reminder
  config.

  Public because it is the single authority on entry-matching, shared with
  `Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails`, which reads
  `reminders_sent` to decide whether a reminder still needs sending: writer
  and reader must never disagree about which entry a `(value, unit)` config
  identifies.
  """
  @spec reminder_entry_match?(map(), integer(), String.t()) :: boolean()
  def reminder_entry_match?(entry, val, unit) do
    case entry do
      %{"value" => v, "unit" => u} -> v == val and u == unit
      %{value: v, unit: u} -> v == val and u == unit
      _other -> false
    end
  end

  defp merge_reminder_entry(entry, val, unit, organizer_sent, attendee_sent) do
    %{
      "value" => val,
      "unit" => unit,
      "organizer_sent" =>
        reminder_entry_flag(entry, "organizer_sent", :organizer_sent) or organizer_sent,
      "attendee_sent" =>
        reminder_entry_flag(entry, "attendee_sent", :attendee_sent) or attendee_sent
    }
  end

  @doc """
  Whether a `reminders_sent` entry records the recipient identified by
  `string_key`/`atom_key` as sent.

  Missing keys mean a pre-upsert entry; treated as already sent rather than
  guessing, so old rows never trigger a fresh send. Public and shared with
  `Tymeslot.Workers.EmailWorkerHandlers.MeetingEmails`, the reader of this
  field: this is the single authority on legacy-entry semantics, so the
  default here cannot silently diverge from what the reader assumes.
  """
  @spec reminder_entry_flag(map(), String.t(), atom()) :: boolean()
  def reminder_entry_flag(entry, string_key, atom_key) do
    case entry do
      %{^string_key => sent} when is_boolean(sent) -> sent
      %{^atom_key => sent} when is_boolean(sent) -> sent
      _other -> true
    end
  end

  @doc """
  Counts upcoming live bookings holding a provider room created by the given
  integration.

  Drives the "N upcoming bookings use this" line in the disconnect modal, so the
  user knows what the optional room cleanup would affect before choosing it.
  """
  @spec count_upcoming_with_video_room_for_integration(pos_integer(), DateTime.t()) ::
          non_neg_integer()
  def count_upcoming_with_video_room_for_integration(integration_id, %DateTime{} = now) do
    Meeting
    |> MeetingState.where_live_booking()
    |> where([m], m.end_time > ^now)
    |> where([m], m.video_integration_id == ^integration_id)
    |> where([m], not is_nil(m.video_room_id))
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Returns the count of bookings created for an organizer within the given
  window. Used by the analytics dashboard to compute conversion rate.
  """
  @spec count_bookings(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_bookings(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Lists the start times (and meeting type) of an organizer's slot-occupying
  bookings whose `start_time` falls in `[from_utc, to_utc)`.

  Counts only meetings that hold a slot (`MeetingState.where_slot_live/1`), so
  cancelled, completed and expired bookings are excluded. Used by the booking
  limits feature to bucket bookings into host-timezone periods.

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
        opts \\ []
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
  Returns the count of bookings grouped by `utm_source` for an organizer
  within the given window. Only returns rows where `utm_source` is set.
  Intended as a primitive for analytics composition — callers should not
  interpret the shape; use `Tymeslot.Analytics.attribution_table/3` instead.
  """
  @spec count_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), bookings: non_neg_integer()}
        ]
  def count_by_utm_source(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.utm_source))
    |> group_by([m], m.utm_source)
    |> select([m], %{utm_source: m.utm_source, bookings: count(m.id)})
    |> Repo.all()
  end

  @doc """
  Counts distinct converting visitors (meetings carrying a `visitor_hash`) for
  an organizer within the window. See `Tymeslot.Meetings.count_converting_visitors/3`.
  """
  @spec count_converting_visitors(integer(), DateTime.t(), DateTime.t()) :: non_neg_integer()
  def count_converting_visitors(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.visitor_hash))
    |> select([m], count(m.visitor_hash, :distinct))
    |> Repo.one() || 0
  end

  @doc """
  Returns distinct converting-visitor counts grouped by `utm_source` for an
  organizer within the window. Only rows where both `utm_source` and
  `visitor_hash` are set.
  """
  @spec converting_visitors_by_utm_source(integer(), DateTime.t(), DateTime.t()) :: [
          %{utm_source: String.t(), converting_visitors: non_neg_integer()}
        ]
  def converting_visitors_by_utm_source(organizer_user_id, %DateTime{} = from, %DateTime{} = to) do
    Meeting
    |> where([m], m.organizer_user_id == ^organizer_user_id)
    |> where([m], m.inserted_at >= ^from and m.inserted_at <= ^to)
    |> where([m], not is_nil(m.utm_source))
    |> where([m], not is_nil(m.visitor_hash))
    |> group_by([m], m.utm_source)
    |> select([m], %{
      utm_source: m.utm_source,
      converting_visitors: count(m.visitor_hash, :distinct)
    })
    |> Repo.all()
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
