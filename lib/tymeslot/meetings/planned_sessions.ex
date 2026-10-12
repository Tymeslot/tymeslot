defmodule Tymeslot.Meetings.PlannedSessions do
  @moduledoc """
  The sessions a host plans on a fixed-date group meeting type
  (`Tymeslot.MeetingTypes.FixedDates`).

  A session is the type's group meeting row itself, created by the host
  before anyone has signed up and flagged `planned`. Everything a group
  slot already does then applies to it unchanged: bookers join it as
  participants (`Tymeslot.Meetings.GroupScheduling` finds the live row by
  type and start time), its calendar event is kept in step with them, its
  reminders and video room are its own, and the host cancels it like any
  other group meeting, telling everyone booked on it.

  What is different is that the session exists because it was planned, not
  because somebody booked it:

    * it is on the host's calendar from the moment it is planned;
    * it stays when its last participant leaves
      (`Tymeslot.Bookings.SeatRelease`);
    * it is offered until registration closes, at `registration_closes_at`
      or, without one, at its start (`open?/2`), rather than by the type's
      availability schedule.
  """

  require Logger

  alias Ecto.UUID
  alias Tymeslot.Bookings.{BuildParams, CalendarJobs, Policy, SeatEffects}
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.Cancellation
  alias Tymeslot.Meetings.GroupMeetingQueries
  alias Tymeslot.Meetings.MeetingSchema, as: Meeting
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MeetingTypes.FixedDates

  @type add_error ::
          :not_fixed_dates
          | :start_in_past
          | :invalid_registration_close
          | :time_conflict
          | {:validation_error, Ecto.Changeset.t()}
          | term()

  @doc "The type's live planned sessions, in start order, past ones included."
  @spec list(map()) :: [Meeting.t()]
  def list(%{id: meeting_type_id}), do: GroupMeetingQueries.list_planned_for_type(meeting_type_id)

  @doc "The type's live planned sessions that have not started yet, in start order."
  @spec upcoming(map(), DateTime.t()) :: [Meeting.t()]
  def upcoming(%{id: meeting_type_id}, now \\ Clock.utc_now()),
    do: GroupMeetingQueries.list_planned_for_type(meeting_type_id, now)

  @doc "How many people are booked on `session`: its live participants, not their guests."
  @spec participant_count(Meeting.t()) :: non_neg_integer()
  def participant_count(%Meeting{id: id}), do: ParticipantQueries.count_live_for_meeting(id)

  @doc """
  When registration for `session` closes: its `registration_closes_at`, or
  its start when it has none.
  """
  @spec registration_closes_at(Meeting.t()) :: DateTime.t()
  def registration_closes_at(%Meeting{registration_closes_at: %DateTime{} = closes_at}),
    do: closes_at

  def registration_closes_at(%Meeting{start_time: start_time}), do: start_time

  @doc "Whether people can still sign up for `session` at `now`."
  @spec open?(Meeting.t(), DateTime.t()) :: boolean()
  def open?(%Meeting{planned: true} = session, now \\ Clock.utc_now()) do
    DateTime.compare(now, registration_closes_at(session)) == :lt
  end

  @doc """
  Plans a session of `meeting_type` starting at `starts_at` (UTC), lasting
  the type's duration and holding its participant limit.

  `:registration_closes_at` is optional; when given it must lie in the
  future and not after the start. The session must not overlap another of
  the host's Tymeslot bookings, but the host's booking limits do not apply:
  they meter bookings people make, and this is the host's own plan.

  Once it is stored, its calendar event, reminders and video room are
  scheduled exactly as for a slot a first booking created.
  """
  @spec add(map(), DateTime.t(), keyword()) :: {:ok, Meeting.t()} | {:error, add_error()}
  def add(meeting_type, %DateTime{} = starts_at, opts \\ []) do
    now = Keyword.get(opts, :now, Clock.utc_now())
    starts_at = DateTime.truncate(starts_at, :second)

    closes_at =
      case Keyword.get(opts, :registration_closes_at) do
        %DateTime{} = closes_at -> DateTime.truncate(closes_at, :second)
        nil -> nil
      end

    with :ok <- check_fixed_dates(meeting_type),
         :ok <- check_start(starts_at, now),
         :ok <- check_registration_close(closes_at, starts_at, now),
         {:ok, session} <-
           meeting_type
           |> session_attrs(starts_at, closes_at)
           |> Scheduling.create_group_meeting_with_conflict_check(enforce_booking_limits: false) do
      schedule_session_effects(session)
      {:ok, session}
    end
  end

  @doc """
  Cancels a planned session the host owns, through the host's own cancel
  path, which tells everyone booked on it.
  """
  @spec cancel(Meeting.t(), integer()) :: {:ok, Meeting.t()} | {:error, term()}
  def cancel(%Meeting{planned: true, organizer_user_id: user_id} = session, user_id),
    do: Cancellation.cancel(session, user_id, :none)

  def cancel(_session, _user_id), do: {:error, :not_found}

  defp check_fixed_dates(meeting_type) do
    if FixedDates.enabled?(meeting_type), do: :ok, else: {:error, :not_fixed_dates}
  end

  defp check_start(starts_at, now) do
    if DateTime.compare(starts_at, now) == :gt, do: :ok, else: {:error, :start_in_past}
  end

  defp check_registration_close(nil, _starts_at, _now), do: :ok

  defp check_registration_close(closes_at, starts_at, now) do
    if DateTime.compare(closes_at, now) == :gt and DateTime.compare(closes_at, starts_at) != :gt,
      do: :ok,
      else: {:error, :invalid_registration_close}
  end

  # The attributes a first booking would give the slot (organiser, location,
  # video integration, reminders, calendar destination), built by the same
  # `Policy.build_meeting_attributes/1`, then cut back to the slot by
  # `SeatEffects.slot_attrs/2` as a seat's slot is: a session has no booker.
  defp session_attrs(meeting_type, starts_at, closes_at) do
    duration = meeting_type.duration_minutes

    %{
      meeting_uid: UUID.generate(),
      form_data: %{},
      start_datetime: starts_at,
      end_datetime: DateTime.add(starts_at, duration, :minute),
      duration_minutes: duration,
      organizer_user_id: meeting_type.user_id,
      meeting_type_id: meeting_type.id
    }
    |> BuildParams.new()
    |> Policy.build_meeting_attributes()
    |> SeatEffects.slot_attrs(meeting_type.name)
    |> Map.merge(%{
      capacity: meeting_type.max_participants,
      planned: true,
      registration_closes_at: closes_at
    })
  end

  defp schedule_session_effects(session) do
    with {:ok, _job} <- CalendarJobs.schedule_job(session, "create"),
         {:ok, _defer?} <- SeatEffects.schedule_new_slot_effects(session) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Failed to schedule the jobs of a planned session",
          meeting_id: session.id,
          reason: LogFormat.reason(reason)
        )
    end

    SeatEffects.broadcast_and_invalidate(session)
  end
end
