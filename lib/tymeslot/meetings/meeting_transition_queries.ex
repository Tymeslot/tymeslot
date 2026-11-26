defmodule Tymeslot.Meetings.MeetingTransitionQueries do
  @moduledoc """
  The guarded status transitions on meetings.

  Each is a single `UPDATE ... WHERE` whose guard is in the `WHERE` clause
  rather than read-then-write, so of several callers racing on one meeting
  exactly one changes the row and receives it; every other gets an error and
  must not repeat the transition's side effects. The approval gate
  (`Tymeslot.Meetings.Approval`), email verification and cancellation all
  rely on that.
  """

  import Ecto.Query, warn: false

  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Repo

  @doc """
  Moves a meeting out of `:awaiting_approval`, atomically.

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
        where: m.id == ^meeting_id and m.status == :awaiting_approval,
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
  Moves a held-for-verification meeting onward, atomically.

  One guarded `UPDATE ... WHERE id = $1 AND status = 'awaiting_verification'`,
  so of two callers (the attendee's link and the expiry sweep, say) only the
  first finds a row to change; the other gets `{:error, :not_awaiting_verification}`.

  With `deadline_after: now` the guard also requires the verification
  deadline to be ahead of `now`, which is how a verification is refused once
  its window has closed; the same error is returned, and the caller reads the
  row to say which guard failed. Releases pass no deadline: they apply at any
  time.

  The held row is already in the unique index on confirmed-or-held slots and
  every transition out of the gate stays within or leaves its predicate, so
  no unique violation can arise here.
  """
  @spec transition_from_awaiting_verification(Ecto.UUID.t(), keyword(), keyword()) ::
          {:ok, Meeting.t()} | {:error, :not_awaiting_verification}
  def transition_from_awaiting_verification(meeting_id, changes, opts \\ [])
      when is_list(changes) and is_list(opts) do
    now = DateTime.utc_now(:second)

    held =
      from(m in Meeting,
        where: m.id == ^meeting_id and m.status == :awaiting_verification,
        select: m
      )

    query = where_deadline_after(held, Keyword.get(opts, :deadline_after))

    case Repo.update_all(query, set: Keyword.put_new(changes, :updated_at, now)) do
      {1, [meeting]} -> {:ok, meeting}
      {0, _none} -> {:error, :not_awaiting_verification}
    end
  end

  @doc """
  Holds a confirmed group slot for email verification again, atomically: the
  way back from `transition_from_awaiting_verification/3` for a slot whose
  last counting seat has left while held seats remain on it
  (`Tymeslot.Bookings.SeatRelease`).

  Guarded on `status = 'confirmed'`; any other row is left alone and
  `{:error, :not_confirmed}` returned. Both statuses sit in the unique index
  on confirmed-or-held slots, so no unique violation can arise here.
  """
  @spec transition_to_awaiting_verification(Ecto.UUID.t(), keyword()) ::
          {:ok, Meeting.t()} | {:error, :not_confirmed}
  def transition_to_awaiting_verification(meeting_id, changes) when is_list(changes) do
    now = DateTime.utc_now(:second)

    query =
      from(m in Meeting,
        where: m.id == ^meeting_id and m.status == :confirmed,
        select: m
      )

    changes = Keyword.merge(changes, status: :awaiting_verification, updated_at: now)

    case Repo.update_all(query, set: changes) do
      {1, [meeting]} -> {:ok, meeting}
      {0, _none} -> {:error, :not_confirmed}
    end
  end

  defp where_deadline_after(query, nil), do: query

  defp where_deadline_after(query, %DateTime{} = now),
    do: where(query, [m], m.verification_deadline_at > ^now)

  @doc """
  Counts one more verification email for a held booking, atomically, and
  returns the meeting with its new count.

  The guard is in the `WHERE` clause, so two concurrent resends cannot both
  pass the cap: the booking must still be `:awaiting_verification`, its
  deadline still ahead of `now`, and fewer than `max_sends` emails counted. A
  `NULL` count is the one email sent with the booking. `{:error, :refused}`
  when any guard fails; the caller reads the row to say which.
  """
  @spec count_verification_email(Ecto.UUID.t(), DateTime.t(), pos_integer()) ::
          {:ok, Meeting.t()} | {:error, :refused}
  def count_verification_email(meeting_id, %DateTime{} = now, max_sends)
      when is_integer(max_sends) do
    query =
      from(m in Meeting,
        where:
          m.id == ^meeting_id and m.status == :awaiting_verification and
            m.verification_deadline_at > ^now and
            coalesce(m.verification_emails_sent, 1) < ^max_sends,
        select: m,
        update: [
          set: [
            verification_emails_sent: fragment("COALESCE(?, 1) + 1", m.verification_emails_sent),
            updated_at: ^DateTime.truncate(now, :second)
          ]
        ]
      )

    case Repo.update_all(query, []) do
      {1, [meeting]} -> {:ok, meeting}
      {0, _none} -> {:error, :refused}
    end
  end

  @doc """
  Moves a meeting to `:cancelled`, atomically, unless it is already over.

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
      |> Keyword.put(:status, :cancelled)
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
  Moves a meeting whose reschedule request lapsed unanswered to `:expired`,
  atomically, keeping `reschedule_requested_at` as the record of why.

  The guard (`MeetingState.where_reschedule_request_lapsed/2` at `now`, and
  the request still being the one stamped at `requested_at`) is in the
  `WHERE` clause: the attendee picking a new time clears the request under
  the meeting's row lock, so of the two, whichever commits first wins and the
  other finds nothing to change. A later request on the same meeting carries
  its own deadline and is not ended by an earlier one's expiry.
  `{:error, :not_lapsed}` when nothing matched.

  `cancelled_at` is the request's deadline
  (`MeetingState.reschedule_request_deadline/1`), computed from the row,
  rather than `now`: the request ended there, and a job or sweep that runs
  late must not date it to whenever it ran.
  """
  @spec expire_reschedule_request(Ecto.UUID.t(), DateTime.t(), DateTime.t()) ::
          {:ok, Meeting.t()} | {:error, :not_lapsed}
  def expire_reschedule_request(meeting_id, %DateTime{} = requested_at, %DateTime{} = now) do
    now = DateTime.truncate(now, :second)

    request =
      from(m in Meeting,
        where: m.id == ^meeting_id and m.reschedule_requested_at == ^requested_at,
        select: m
      )

    days = MeetingState.reschedule_answer_days()

    query =
      request
      |> MeetingState.where_reschedule_request_lapsed(now)
      |> update([m],
        set: [
          status: :expired,
          cancelled_at:
            fragment(
              "date_trunc('second', GREATEST(?, ? + make_interval(days => ?)))",
              m.start_time,
              m.reschedule_requested_at,
              ^days
            ),
          updated_at: ^now
        ]
      )

    case Repo.update_all(query, []) do
      {1, [meeting]} -> {:ok, meeting}
      {0, _none} -> {:error, :not_lapsed}
    end
  end
end
