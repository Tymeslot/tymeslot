defmodule Tymeslot.Meetings.MeetingDeliveryQueries do
  @moduledoc """
  Database writes that record what has been delivered for a meeting: the
  claim on its `meeting.created` announcement, the sent-email flags and the
  per-recipient reminder bookkeeping. Each is the durable half of a
  notification's idempotency, so a retried job or a racing caller can tell
  what has already gone out.

  It also answers whether a delivery is being attempted inside a
  transaction (`in_transaction?/0`), which the integration fan-out must not
  be.
  """

  import Ecto.Query, warn: false

  alias Ecto.Changeset
  alias Ecto.UUID
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ReminderEntry
  alias Tymeslot.Repo

  @doc """
  Claims the `meeting.created` announcement for a meeting.

  Returns `:ok` to exactly one caller and `:already_announced` to every one
  after it, so an event deferred to `Tymeslot.Workers.VideoRoomWorker` cannot
  fan out a second time when a room finally arrives after recovery has already
  announced the booking without one.

  The claim is a single conditional UPDATE rather than a read followed by a
  write, so two callers racing on the same meeting cannot both win it.

  A winning claim also says whether the booking has been announced before:
  `{:ok, :re_announcement}` when a reschedule sent a confirmed booking back
  into the approval gate (which clears `announced_at` but never
  `first_announced_at`) and the host has now approved the new time,
  `{:ok, :first_announcement}` otherwise. The answer is read from the row the
  UPDATE locks, in the same statement, rather than from the caller's struct,
  so a stale struct cannot turn a first announcement into a repeat or the
  other way round.
  """
  @spec claim_announcement(term()) ::
          {:ok, :first_announcement | :re_announcement} | :already_announced
  def claim_announcement(meeting_id) do
    case UUID.cast(meeting_id) do
      {:ok, uuid} -> claim_announcement_for(uuid)
      # Nothing to dedupe against, so let the caller announce rather than
      # swallow an event on the strength of an id we cannot look up.
      :error -> {:ok, :first_announcement}
    end
  end

  defp claim_announcement_for(uuid) do
    now = DateTime.utc_now(:second)

    # The self-join exposes the row as it stood before this UPDATE: RETURNING
    # on the target itself would only show the COALESCE result, which is
    # `now` for a first announcement and indistinguishable from an earlier
    # stamp taken within the same second.
    {claimed, previous} =
      Repo.update_all(
        from(m in Meeting,
          join: before in Meeting,
          on: before.id == m.id,
          where: m.id == ^uuid and is_nil(m.announced_at),
          select: before.first_announced_at,
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
      claimed == 1 and previous == [nil] -> {:ok, :first_announcement}
      claimed == 1 -> {:ok, :re_announcement}
      Repo.exists?(from(m in Meeting, where: m.id == ^uuid)) -> :already_announced
      # The meeting is gone, or was never persisted. Either way there is no
      # stamp to read, and refusing to announce would be the worse failure.
      true -> {:ok, :first_announcement}
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
      MeetingQueries.update_meeting(meeting, attrs)
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
      case MeetingQueries.get_meeting_for_update(meeting.id) do
        {:ok, locked_meeting} ->
          updated_list =
            merge_reminder_sent(
              locked_meeting.reminders_sent,
              val,
              unit,
              organizer_sent,
              attendee_sent
            )

          case MeetingQueries.update_meeting(locked_meeting, %{
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
        if ReminderEntry.for_reminder?(entry, val, unit) do
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

  defp merge_reminder_entry(entry, val, unit, organizer_sent, attendee_sent) do
    %{
      "value" => val,
      "unit" => unit,
      "organizer_sent" => ReminderEntry.sent?(entry, :organizer) or organizer_sent,
      "attendee_sent" => ReminderEntry.sent?(entry, :attendee) or attendee_sent
    }
  end

  @doc """
  Whether the calling process is inside a database transaction.
  `Tymeslot.Notifications.Events.dispatch_deferred/1` refuses to run in one.
  """
  @spec in_transaction?() :: boolean()
  def in_transaction?, do: Repo.in_transaction?()
end
