defmodule Tymeslot.Notifications.ReminderSchedule do
  @moduledoc """
  What a meeting reminds with, and how far those reminders have got.

  A booking carries its own reminder list, copied from the meeting type at
  booking time — so the meeting type's current setting is not the answer for a
  booking made before it changed, and a meeting quick-added without one has no
  meeting type to ask at all. This module is the one place that reads the
  meeting's own column, including the legacy shapes older rows still carry, so
  what a surface *shows* and what `Orchestrator` *schedules* cannot drift
  apart.

  `nil` and `[]` are different answers: an empty list is a booking that asked
  for no reminders, while `nil` is a row from before the column existed, which
  falls back to the legacy fields and finally to 30 minutes — exactly the
  reminder such a booking actually receives.
  """

  alias Tymeslot.Clock
  alias Tymeslot.Jobs.ObanJobQueries
  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.Notifications.SchedulingRules
  alias Tymeslot.Utils.ReminderUtils
  alias Tymeslot.Workers.EmailWorker

  @legacy_default "30 minutes"

  @type reminder :: %{value: pos_integer(), unit: String.t()}
  @typedoc "The reminders a meeting has a job waiting to send, as `{value, unit}`."
  @type scheduled :: MapSet.t({pos_integer(), String.t()})
  @type status :: %{
          value: pos_integer(),
          unit: String.t(),
          status:
            :sent
            | :not_sent
            | :after_approval
            | :after_payment
            | :after_rescheduling
            | :upcoming
            | :not_scheduled
        }

  @doc """
  The reminders a meeting is scheduled with, in the order they were configured.
  """
  @spec configured(%{atom() => term()}) :: [reminder()]
  def configured(meeting) do
    case Map.get(meeting, :reminders) do
      nil -> [legacy_reminder(meeting)]
      reminders -> ReminderUtils.normalize_reminders(reminders)
    end
  end

  @doc """
  The reminders each of `meetings` has a job still waiting to send, keyed by
  meeting id, in one query for the whole list. A meeting with none is absent;
  read it with `Map.get(scheduled, id, MapSet.new())`.

  This is what `with_status/3` needs to say "not yet sent" truthfully: the
  configured list is only what a booking *asked* for, while a job is what
  actually sends. Scheduling can be refused (`Orchestrator` validates the
  recipients first) or fail to enqueue, and either leaves a reminder with
  nothing behind it.
  """
  @spec scheduled_by_meeting([%{id: term()}]) :: %{term() => scheduled()}
  def scheduled_by_meeting(meetings) do
    ids = Enum.map(meetings, & &1.id)

    EmailWorker
    |> ObanJobQueries.pending_reminder_jobs(ids)
    |> Enum.flat_map(&scheduled_entry/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, reminders} -> {id, MapSet.new(reminders)} end)
  end

  @doc """
  The same reminders, each carrying where it stands at `now`. `scheduled` is
  this meeting's entry from `scheduled_by_meeting/1`.

  - `:sent`: `reminders_sent` records it reaching the organiser or the
    attendee. Guests are stamped per guest rather than on the meeting, so this
    says the reminder fired, not that every guest was reached.
  - `:not_sent`: its moment has passed without it going out, typically
    because the booking was made too late for it, or it was held until then.
  - `:after_approval`, `:after_payment`, `:after_rescheduling`: the booking is
    held, so no reminder job exists yet; one is scheduled once the hold ends.
  - `:upcoming`: a job is waiting to send it.
  - `:not_scheduled`: still ahead, but nothing will send it: scheduling was
    refused or failed, or the booking has not been announced yet.

  A booking released without taking place (cancelled, or a request that
  expired) has none left: its pending reminder jobs went with it.
  """
  @spec with_status(%{atom() => term()}, scheduled(), DateTime.t()) :: [status()]
  def with_status(meeting, scheduled, now \\ Clock.utc_now()) do
    if MeetingState.released_status?(meeting.status) do
      []
    else
      sent = meeting |> Map.get(:reminders_sent) |> List.wrap()

      Enum.map(configured(meeting), fn reminder ->
        Map.put(reminder, :status, status(meeting, reminder, sent, scheduled, now))
      end)
    end
  end

  # --- Private helpers ---

  # A held booking is asked before the job: the worker skips a voided slot
  # even when a job slipped through, so the hold is what decides. A job whose
  # moment has passed is still coming (the queue is behind, or it is running),
  # so it is asked before the clock.
  defp status(meeting, %{value: value, unit: unit} = reminder, sent, scheduled, now) do
    fires_at = SchedulingRules.calculate_reminder_time(meeting.start_time, value, unit)
    job? = MapSet.member?(scheduled, {value, unit})

    cond do
      sent?(sent, reminder) -> :sent
      not job? and DateTime.compare(fires_at, now) != :gt -> :not_sent
      MeetingState.awaiting_approval?(meeting) -> :after_approval
      MeetingState.awaiting_payment?(meeting) -> :after_payment
      MeetingState.awaiting_new_time?(meeting) -> :after_rescheduling
      job? -> :upcoming
      true -> :not_scheduled
    end
  end

  # Args written by an older scheduler, or by hand, that do not normalise are
  # a job this module cannot match to a reminder, so they are left out.
  defp scheduled_entry({meeting_id, value, unit}) do
    case ReminderUtils.normalize_reminder(%{value: value, unit: unit}) do
      {:ok, %{value: value, unit: unit}} -> [{meeting_id, {value, unit}}]
      _invalid -> []
    end
  end

  defp legacy_reminder(meeting) do
    label =
      Map.get(meeting, :reminder_time) || Map.get(meeting, :default_reminder_time) ||
        @legacy_default

    %{
      value: ReminderUtils.parse_reminder_value(label),
      unit: ReminderUtils.normalize_reminder_unit(label)
    }
  end

  defp sent?(entries, %{value: value, unit: unit}) do
    case Enum.find(entries, &entry_match?(&1, value, unit)) do
      nil ->
        false

      entry ->
        flag(entry, "organizer_sent", :organizer_sent) or
          flag(entry, "attendee_sent", :attendee_sent)
    end
  end

  defp entry_match?(entry, value, unit) do
    case entry do
      %{"value" => v, "unit" => u} -> v == value and u == unit
      %{value: v, unit: u} -> v == value and u == unit
      _other -> false
    end
  end

  # A pre-upsert entry carries no per-recipient flags. It is read as sent
  # rather than guessed at, the same way the reminder worker reads it: the
  # entry exists because the reminder fired.
  defp flag(entry, string_key, atom_key) do
    case entry do
      %{^string_key => sent} when is_boolean(sent) -> sent
      %{^atom_key => sent} when is_boolean(sent) -> sent
      _other -> true
    end
  end
end
