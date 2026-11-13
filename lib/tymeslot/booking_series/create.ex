defmodule Tymeslot.BookingSeries.Create do
  @moduledoc """
  Books a series: every session an ordinary meeting, linked to one
  `booking_series` row, all in one transaction. All or nothing: a session
  that cannot be booked refuses the whole series, and nothing is written.

  The submission takes the steps a single booking takes before its time is
  judged (`Tymeslot.Bookings.Create.Prepare`), then every session is judged
  at once (`Tymeslot.BookingSeries.Check`), with the host's calendars read
  strictly: a calendar that cannot be reached refuses the series rather than
  booking months of sessions over clashes nobody could see. The transaction
  takes the organiser's schedule lock, and each session is then inserted
  through `Scheduling.create_meeting_with_conflict_check/2`, which counts
  conflicts and booking limits again under it; the sessions inserted before
  it count, as they are in the same transaction.

  Each session keeps its own manage links, reminders, calendar event and
  video room. Its confirmation is the series' own, one for all of them
  (`Tymeslot.BookingSeries.Notifications`), so the sessions are announced
  with `announce: :series` (`Tymeslot.Bookings.Activation`).

  Group, paid and approval types are not booked as a series yet, and are
  refused with `:series_not_offered`.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.Schedules

  alias Tymeslot.Bookings.{
    Activation,
    BuildParams,
    Errors,
    MeetingAttributes,
    Telemetry
  }

  alias Tymeslot.Bookings.Create.{Persist, Prepare}
  alias Tymeslot.BookingSeries.{Check, Notifications, Occurrence, Plan, SeriesQueries}
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias Tymeslot.Repo
  alias Tymeslot.Timezones
  alias UUID

  @type series_request ::
          %{mode: :recurring, first_start: DateTime.t(), count: pos_integer()}
          | %{mode: :flexible, starts: [DateTime.t()]}

  @type result ::
          {:ok, %{series: SeriesSchema.t(), meetings: [MeetingSchema.t()]}}
          | {:error, Errors.classified_error()}

  # A session the transaction found taken, as the check would have judged it.
  @lost_in_lock %{time_conflict: :booked, booking_limit_reached: :limit_reached}

  @doc """
  Books the series `meeting_params.series` asks for (`t:series_request/0`),
  with the rest of `meeting_params` and `form_data` as a single booking
  takes them.

  Returns the series and its meetings in position order, or
  `{:error, {:occurrences_unavailable, occurrences}}` with only the sessions
  that cannot be booked, or any other `Tymeslot.Bookings.Errors` reason.

  Options: `:with_video_room`, as `Tymeslot.Bookings.Create.execute/3`.
  """
  @spec execute(map(), map(), keyword()) :: result()
  def execute(meeting_params, form_data, opts \\ []) do
    booking_data = Prepare.common(meeting_params, form_data)

    with :ok <- Prepare.validate_custom_field_answers(booking_data),
         :ok <- ensure_offered(booking_data),
         :ok <- Prepare.validate_admission(booking_data),
         {:ok, plan} <- plan(booking_data, Map.get(meeting_params, :series)),
         {:ok, occurrences} <- check(plan, booking_data),
         :ok <- all_available(occurrences) do
      book(plan, occurrences, booking_data, opts)
    else
      {:error, reason} -> {:error, Errors.classify_error(reason)}
    end
  end

  # `SeriesSettings.offered?/1` asks the host's plan, so it is asked once.
  # A booking made without a type (or for a type that is not the host's,
  # refused by the admission check next) has no series to book.
  defp ensure_offered(%{meeting_type: nil, meeting_type_id: nil}),
    do: {:error, :series_not_offered}

  defp ensure_offered(%{meeting_type: nil}), do: :ok

  defp ensure_offered(%{meeting_type: %MeetingTypeSchema{} = type} = booking_data) do
    cond do
      not SeriesSettings.offered?(type) -> {:error, :series_not_offered}
      not_yet_bookable_as_series?(type, booking_data) -> {:error, :series_not_offered}
      true -> :ok
    end
  end

  # Not booked as a series yet: a group type's sessions are seats, a paid
  # type's take one payment for all of them, and an approval type's are
  # requested as one.
  defp not_yet_bookable_as_series?(type, booking_data) do
    MeetingTypeSchema.group?(type) or Prepare.paid?(booking_data) or Approval.required?(type)
  end

  # Plan

  defp plan(%{meeting_type: type} = booking_data, request) do
    with {:ok, booker_tz} <- booker_tz(booking_data.user_timezone) do
      opts = [
        booker_tz: booker_tz,
        duration_minutes: booking_data.duration_minutes,
        config: Schedules.booking_config(booking_data.organizer_user_id, type)
      ]

      plan_for(type.series_mode, request, type, opts)
    end
  end

  defp booker_tz(nil), do: {:ok, nil}

  defp booker_tz(timezone) do
    if Timezones.valid?(timezone), do: {:ok, timezone}, else: {:error, :invalid_datetime}
  end

  defp plan_for(
         :recurring,
         %{mode: :recurring, first_start: %DateTime{} = first, count: count},
         type,
         opts
       ),
       do: Plan.recurring(type, first, count, opts)

  defp plan_for(:flexible, %{mode: :flexible, starts: starts}, type, opts)
       when is_list(starts) do
    if Enum.all?(starts, &match?(%DateTime{}, &1)),
      do: Plan.flexible(type, starts, opts),
      else: {:error, :invalid_datetime}
  end

  # A request in the other mode than the type's, or a malformed one.
  defp plan_for(_mode, _request, _type, _opts), do: {:error, :series_not_offered}

  # Every session is judged; the host's calendars are read strictly.
  defp check(plan, booking_data) do
    Check.check(plan,
      booker_email: booking_data.form_data["email"],
      guests: length(booking_data.guest_emails),
      strict_calendar: true
    )
  end

  defp all_available(occurrences) do
    case Enum.reject(occurrences, &Occurrence.available?/1) do
      [] -> :ok
      unavailable -> {:error, {:occurrences_unavailable, unavailable}}
    end
  end

  # Booking

  # The meeting attributes read the host's profile, schedule and
  # integrations, so they are built before the schedule lock is taken.
  defp book(plan, occurrences, booking_data, opts) do
    attrs = Enum.map(occurrences, &occurrence_attrs(&1, booking_data))

    plan
    |> run_transaction(attrs, booking_data, opts)
    |> map_result(occurrences, booking_data)
  end

  defp occurrence_attrs(%Occurrence{} = occurrence, booking_data) do
    booking_data
    |> Map.merge(%{
      meeting_uid: UUID.uuid4(),
      start_datetime: occurrence.start,
      end_datetime: occurrence.end,
      series_position: occurrence.position
    })
    |> BuildParams.new()
    |> MeetingAttributes.build()
  end

  defp run_transaction(plan, attrs, booking_data, opts) do
    activation_opts = [
      announce: :series,
      with_video_room: Keyword.get(opts, :with_video_room, false)
    ]

    Repo.transaction(fn ->
      :ok = MeetingConflictQueries.lock_organizer_schedule(plan.organizer_user_id)
      series = insert_series(plan, booking_data)

      {meetings, pending} =
        Enum.reduce(attrs, {[], []}, fn meeting_attrs, {meetings, pending} ->
          meeting_attrs = %{meeting_attrs | series_id: series.id}

          {meeting, owed} = book_occurrence(meeting_attrs, booking_data, activation_opts)
          {[meeting | meetings], [owed | pending]}
        end)

      # The confirmation commits with the series. The placeholder cannot fail
      # yet; the real one rolls the series back when it does.
      {:ok, _scheduled} = Notifications.schedule_series_confirmation(series)

      {series, Enum.reverse(meetings), pending |> Enum.reverse() |> Enum.concat()}
    end)
  end

  defp insert_series(%Plan{} = plan, booking_data) do
    type = plan.meeting_type
    recurring? = plan.mode == :recurring

    attrs = %{
      organizer_user_id: plan.organizer_user_id,
      meeting_type_id: type.id,
      mode: plan.mode,
      frequency: if(recurring?, do: type.series_frequency),
      interval: if(recurring?, do: type.series_interval),
      occurrences_count: length(plan.starts),
      attendee_name: booking_data.form_data["name"],
      attendee_email: booking_data.form_data["email"],
      attendee_timezone: Timezones.normalize(plan.booker_tz),
      attendee_locale: booking_data.attendee_locale
    }

    case SeriesQueries.insert(attrs) do
      {:ok, series} -> series
      {:error, _changeset} -> Repo.rollback(:validation_error)
    end
  end

  # Each step joins the series' transaction, and a step that fails has
  # already poisoned it, so the first failure rolls back at once, naming the
  # session it happened to.
  defp book_occurrence(meeting_attrs, booking_data, activation_opts) do
    case Persist.persist_and_activate(meeting_attrs, booking_data, activation_opts) do
      {:ok, meeting_and_pending} ->
        meeting_and_pending

      {:error, reason} ->
        Repo.rollback({:occurrence_failed, meeting_attrs.series_position, reason})
    end
  end

  defp map_result({:ok, {series, meetings, pending}}, _occurrences, _booking_data) do
    :ok = Activation.after_commit(pending)
    Availability.changed(series.organizer_user_id)
    Enum.each(meetings, fn _meeting -> Telemetry.booking_created() end)
    {:ok, %{series: series, meetings: meetings}}
  end

  # A session taken between the check and the lock is reported as the check
  # would have reported it, so the booker can choose again.
  defp map_result({:error, {:occurrence_failed, position, reason}}, occurrences, _booking_data)
       when is_map_key(@lost_in_lock, reason) do
    occurrence = Enum.find(occurrences, &(&1.position == position))
    status = {:unavailable, Map.fetch!(@lost_in_lock, reason)}
    {:error, {:occurrences_unavailable, [%{occurrence | status: status}]}}
  end

  defp map_result({:error, {:occurrence_failed, _position, reason}}, _occurrences, booking_data),
    do: {:error, Errors.classify_creation_error(reason, booking_data)}

  defp map_result({:error, reason}, _occurrences, booking_data),
    do: {:error, Errors.classify_creation_error(reason, booking_data)}
end
