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

  On a group type the series takes one seat in each session instead
  (`Tymeslot.Bookings.CreateGroup.book_seat/3`), finding or creating the
  session as a single seat booking does: a fixed-date type's planned
  sessions are only joined. The seats are the series' (each participant
  row carries it); the sessions are shared with other bookers and do not.
  A full session, or one the booker already has a seat in, refuses the
  whole series. No seat sends a confirmation of its own.

  On a paid type (one-to-one only: a group type cannot take payment) every
  session is held `awaiting_payment` instead, with nothing else done for it
  and no confirmation scheduled, and once the series commits one Stripe
  Checkout is opened for all of them (`Tymeslot.BookingSeries.Payment`).
  The result is then `{:ok, :payment_required, %{series, meeting,
  meetings, checkout_url}}`, `meeting` being the first session, whose
  payment pages the checkout returns to.

  On a type requiring approval (one-to-one only: a group type cannot be
  approval-gated) every session is held `awaiting_approval`, all with the
  first session's deadline (`MeetingAttributes.build_series/2`),
  and the series is requested once, for all of them, in place of its
  confirmation (`Notifications.schedule_series_request/1`). The host answers
  for the whole series (`Tymeslot.BookingSeries.Approval`). A paid one is
  held for payment first, and requested once paid.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.Schedules

  alias Tymeslot.Bookings.{
    Activation,
    BuildParams,
    CreateGroup,
    Errors,
    MeetingAttributes,
    SeatEffects,
    Telemetry
  }

  alias Tymeslot.Bookings.Create.{Persist, Prepare}
  alias Tymeslot.BookingSeries.{Check, Notifications, Occurrence, Payment, Plan, SeriesQueries}
  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias Tymeslot.Repo
  alias Tymeslot.Timezones
  alias UUID

  @type series_request ::
          %{mode: :recurring, first_start: DateTime.t(), count: pos_integer()}
          | %{mode: :flexible, starts: [DateTime.t()]}

  @type result ::
          {:ok,
           %{
             series: SeriesSchema.t(),
             meetings: [MeetingSchema.t()],
             participants: [ParticipantSchema.t()]
           }}
          | {:ok, :payment_required,
             %{
               series: SeriesSchema.t(),
               meeting: MeetingSchema.t(),
               meetings: [MeetingSchema.t()],
               checkout_url: String.t()
             }}
          | {:error, Errors.classified_error()}

  # A session the transaction found taken, as the check would have judged it.
  # `:slot_taken` (a first-booker index collision) is not here: with the
  # schedule lock held for the whole series it cannot occur.
  @lost_in_lock %{
    time_conflict: :booked,
    booking_limit_reached: :limit_reached,
    slot_full: :session_full,
    already_booked: :already_booked
  }

  @doc """
  Books the series `meeting_params.series` asks for (`t:series_request/0`),
  with the rest of `meeting_params` and `form_data` as a single booking
  takes them.

  Returns the series, its meetings in position order and, on a group type,
  the booker's seats in them (`participants`, in the same order; empty
  otherwise), or `{:error, {:occurrences_unavailable, occurrences}}` with
  only the sessions that cannot be booked, or any other
  `Tymeslot.Bookings.Errors` reason.

  Options: `:with_video_room`, as `Tymeslot.Bookings.Create.execute/3`.
  """
  @spec execute(map(), map(), keyword()) :: result()
  def execute(meeting_params, form_data, opts \\ []) do
    booking_data = Prepare.common(meeting_params, form_data)

    with :ok <- Prepare.validate_custom_field_answers(booking_data),
         :ok <- ensure_offered(booking_data),
         :ok <- refuse_guests(booking_data),
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

  defp ensure_offered(%{meeting_type: %MeetingTypeSchema{} = type}) do
    if SeriesSettings.offered?(type), do: :ok, else: {:error, :series_not_offered}
  end

  # Guests are not invited to a series' sessions yet, so a series takes
  # none. Only guests the type would have taken count: a list the type
  # ignores (or the booker's own address) refuses nothing.
  defp refuse_guests(booking_data) do
    case CreateGroup.guest_emails(booking_data) do
      [] -> :ok
      [_guest | _rest] -> {:error, :guests_not_allowed_on_series}
    end
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

  # Every session is judged; the host's calendars are read strictly. A
  # series brings no guests (`refuse_guests/1`), so each seat is the
  # booker's alone.
  defp check(plan, booking_data) do
    Check.check(plan,
      booker_email: booking_data.form_data["email"],
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
  # integrations, so they are built before the schedule lock is taken, and
  # once for the whole series.
  defp book(plan, occurrences, booking_data, opts) do
    sessions =
      occurrences
      |> Enum.sort_by(& &1.position)
      |> Enum.map(&session/1)

    attrs = booking_data |> BuildParams.new() |> MeetingAttributes.build_series(sessions)

    plan
    |> run_transaction(attrs, booking_data, opts)
    |> map_result(plan, occurrences, booking_data)
  end

  defp session(%Occurrence{} = occurrence) do
    %{
      meeting_uid: UUID.uuid4(),
      start_datetime: occurrence.start,
      end_datetime: occurrence.end,
      series_position: occurrence.position
    }
  end

  defp run_transaction(plan, attrs, booking_data, opts) do
    book_one = occurrence_booker(plan.meeting_type, booking_data, opts)

    Repo.transaction(fn ->
      :ok = MeetingConflictQueries.lock_organizer_schedule(plan.organizer_user_id)
      series = insert_series(plan, booking_data)

      {booked, pending} =
        Enum.map_reduce(attrs, [], fn meeting_attrs, pending ->
          {one, owed} = book_one.(%{meeting_attrs | series_id: series.id})
          {one, [owed | pending]}
        end)

      :ok = schedule_confirmation(series, booking_data)

      {series, booked, pending |> Enum.reverse() |> Enum.concat()}
    end)
  end

  # The confirmation (or, for a series held for approval, the request)
  # commits with the series: a series nobody would be told about is rolled
  # back and booked again whole. A paid series is confirmed or requested
  # once paid for, by the payment webhook.
  defp schedule_confirmation(series, booking_data) do
    cond do
      Prepare.paid?(booking_data) ->
        :ok

      Approval.required?(booking_data.meeting_type) ->
        settle_scheduled(Notifications.schedule_series_request(series))

      true ->
        settle_scheduled(Notifications.schedule_series_confirmation(series))
    end
  end

  defp settle_scheduled({:ok, _job}), do: :ok
  defp settle_scheduled({:error, reason}), do: Repo.rollback(reason)

  # Books one session inside the series' transaction, returning
  # `{{meeting, seat}, owed}`: the seat is nil for a one-to-one session, and
  # `owed` is the integration fan-out run once the series commits.
  defp occurrence_booker(type, booking_data, opts) do
    with_video_room = Keyword.get(opts, :with_video_room, false)

    cond do
      MeetingTypeSchema.group?(type) ->
        seat_opts = [emails: false, in_outer_transaction: true, with_video_room: with_video_room]
        &book_seat(&1, booking_data, seat_opts)

      Prepare.paid?(booking_data) ->
        &hold_meeting/1

      true ->
        activation_opts = [announce: :series, with_video_room: with_video_room]
        &book_meeting(&1, booking_data, activation_opts)
    end
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
      first_start_at: Enum.min(plan.starts, DateTime),
      attendee_name: booking_data.form_data["name"],
      attendee_email: booking_data.form_data["email"],
      attendee_timezone: Timezones.normalize(plan.booker_tz),
      attendee_locale: booking_data.attendee_locale,
      unit_price_cents: if(Prepare.paid?(booking_data), do: type.price_cents)
    }

    case SeriesQueries.insert(attrs) do
      {:ok, series} -> series
      {:error, _changeset} -> Repo.rollback(:validation_error)
    end
  end

  # Each step joins the series' transaction, and a step that fails has
  # already poisoned it, so the first failure rolls back at once, naming the
  # session it happened to.
  defp book_meeting(meeting_attrs, booking_data, activation_opts) do
    case Persist.persist_and_activate(meeting_attrs, booking_data, activation_opts) do
      {:ok, {meeting, pending}} -> {{meeting, nil}, pending}
      {:error, reason} -> occurrence_failed(meeting_attrs, reason)
    end
  end

  # A paid session is held for the series' payment, with nothing else done.
  defp hold_meeting(meeting_attrs) do
    case Payment.hold(meeting_attrs) do
      {:ok, {meeting, pending}} -> {{meeting, nil}, pending}
      {:error, reason} -> occurrence_failed(meeting_attrs, reason)
    end
  end

  # The seat joins the series' transaction (`in_outer_transaction`), with
  # the organiser lock it takes being the one already held.
  defp book_seat(meeting_attrs, booking_data, seat_opts) do
    case CreateGroup.book_seat(meeting_attrs, booking_data, seat_opts) do
      {:ok, %{meeting: meeting, participant: seat, on_booked_result: pending}} ->
        {{meeting, seat}, pending}

      {:error, reason} ->
        occurrence_failed(meeting_attrs, seat_refusal(reason))
    end
  end

  # The booker's own seat already in the session, caught by the unique
  # index. Postgres has aborted the transaction with it, so this reads the
  # insert's changeset and asks the database nothing more.
  defp seat_refusal(%Ecto.Changeset{} = changeset) do
    if ParticipantSchema.duplicate_seat?(changeset), do: :already_booked, else: changeset
  end

  defp seat_refusal(reason), do: reason

  defp occurrence_failed(meeting_attrs, reason),
    do: Repo.rollback({:occurrence_failed, meeting_attrs.series_position, reason})

  defp map_result({:ok, {series, booked, pending}}, _plan, _occurrences, booking_data) do
    :ok = Activation.after_commit(pending)
    {meetings, seats} = Enum.unzip(booked)
    seats = Enum.reject(seats, &is_nil/1)
    announce_change(booking_data.meeting_type, series, meetings)

    with {:ok, result} <- booked_result(series, meetings, seats, booking_data) do
      Enum.each(booked, fn _booked -> Telemetry.booking_created() end)
      result
    end
  end

  # A session taken between the check and the lock is reported as the check
  # would have reported it, so the booker can choose again.
  defp map_result(
         {:error, {:occurrence_failed, position, reason}},
         plan,
         occurrences,
         booking_data
       )
       when is_map_key(@lost_in_lock, reason) do
    occurrence = Enum.find(occurrences, &(&1.position == position))
    lost = %{occurrence | status: {:unavailable, Map.fetch!(@lost_in_lock, reason)}}
    {:error, {:occurrences_unavailable, lost_with_the_rest(lost, plan, booking_data)}}
  end

  defp map_result({:error, {:occurrence_failed, _position, reason}}, _plan, _occ, booking_data),
    do: {:error, Errors.classify_creation_error(reason, booking_data)}

  defp map_result({:error, reason}, _plan, _occurrences, booking_data),
    do: {:error, Errors.classify_creation_error(reason, booking_data)}

  # The transaction stops at the first session it finds taken, but whatever
  # took it (most often a rival series that won the lock) may have taken
  # later ones too. It has committed by now, so the whole series is judged
  # again, outside any transaction, and every session lost is reported in
  # one answer rather than one per attempt. The session the transaction met
  # is always among them, as it found it; a check that cannot read the
  # calendars this time leaves that one alone to report.
  defp lost_with_the_rest(lost, plan, booking_data) do
    rest =
      case check(plan, booking_data) do
        {:ok, occurrences} ->
          Enum.reject(occurrences, &(Occurrence.available?(&1) or &1.position == lost.position))

        {:error, _unverifiable} ->
          []
      end

    Enum.sort_by([lost | rest], & &1.position)
  end

  # A paid series is held until its checkout, opened now that it has
  # committed, is paid; a checkout that cannot be opened releases it.
  defp booked_result(series, meetings, seats, booking_data) do
    if Prepare.paid?(booking_data) do
      case Payment.checkout(series) do
        {:ok, url} ->
          {:ok,
           {:ok, :payment_required,
            %{series: series, meeting: hd(meetings), meetings: meetings, checkout_url: url}}}

        {:error, reason} ->
          {:error, Errors.classify_creation_error(reason, booking_data)}
      end
    else
      {:ok, {:ok, %{series: series, meetings: meetings, participants: seats}}}
    end
  end

  # Every session of a group series shares its host and type, so one
  # broadcast tells the type's booking pages about every seat taken.
  defp announce_change(type, series, [session | _sessions]) do
    if MeetingTypeSchema.group?(type),
      do: SeatEffects.broadcast_and_invalidate(session),
      else: Availability.changed(series.organizer_user_id)
  end
end
