defmodule Tymeslot.Bookings.Create do
  @moduledoc """
  Orchestrates the booking creation process.
  Combines validation, policy enforcement, and side effects.
  """

  alias Tymeslot.Availability
  alias Tymeslot.Availability.Schedules

  alias Tymeslot.Bookings.{
    Activation,
    BuildParams,
    CalendarCheck,
    CreateGroup,
    Errors,
    MeetingAttributes,
    ScheduleCheck,
    Validation
  }

  alias Tymeslot.Bookings.Create.PaidBooking
  alias Tymeslot.Bookings.Create.Persist
  alias Tymeslot.Bookings.Create.Prepare
  alias Tymeslot.Bookings.Create.VerifiedBooking
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.EmailVerification
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.MeetingTypes.FixedDates
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.MeetingTypes.SeriesSettings
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  @type meeting_params :: %{
          required(:date) => Date.t() | String.t(),
          required(:time) => String.t(),
          required(:duration) => integer() | String.t(),
          required(:user_timezone) => String.t(),
          optional(atom()) => term()
        }
  @type form_data :: %{optional(String.t()) => term()}
  @type booking_data :: map()

  @type error_reason :: String.t() | atom() | {:validation_error, any()}

  @typedoc """
  Result returned by `execute/3`.

  The domain layer classifies every failure reason into one of
  `Tymeslot.Bookings.Errors.classified_error/0`. Rendering an atom to user-facing copy is entirely the
  web layer's responsibility — see
  `TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage`.
  """
  @type execute_result ::
          {:ok, map()}
          | {:ok, :payment_required,
             %{
               required(:meeting) => map(),
               required(:checkout_url) => String.t(),
               optional(:seat_hold) => map()
             }}
          | {:error, Errors.classified_error()}

  @doc """
  Creates a booking with fresh calendar validation.

  This is the single entry point for creating bookings. The cheap checks
  (meeting type, payments, booking window, schedule, limits) run first, and
  only a booking that passes them all pays for the one fresh read of the
  host's calendars (`CalendarCheck.enforce/3`).

  Options:
    - :with_video_room - Create with video room integration (the public
      booking page always sets it)

  When the booking's meeting type has `payment_required: true`, the meeting
  is persisted with status `awaiting_payment` (on a group type, the booker's
  seats are held on the slot instead, and the map also carries the
  `:seat_hold`), side effects (calendar, video, email) are deferred until
  payment confirmation, and a Stripe Checkout Session URL is returned
  alongside the meeting via the `{:ok, :payment_required, ...}` tuple.

  When it has `requires_email_verification: true` (and is not paid), the
  meeting is persisted with status `awaiting_verification`, holding its slot,
  and only the verification email to the attendee is sent; everything an
  ungated booking does at creation waits for
  `Tymeslot.Meetings.EmailVerification.verify/1`
  (`Tymeslot.Bookings.Create.VerifiedBooking`).
  """
  @spec execute(meeting_params(), form_data(), keyword()) :: execute_result()
  def execute(meeting_params, form_data, opts \\ []) do
    with {:ok, booking_data} <- Prepare.booking_data(meeting_params, form_data),
         :ok <- Prepare.validate_custom_field_answers(booking_data),
         {:ok, :validated} <- validate_booking(booking_data) do
      create_meeting_and_all_side_effects_atomically(booking_data, opts)
    else
      {:error, reason} -> {:error, Errors.classify_error(reason)}
    end
  end

  # Private functions

  defp validate_booking(booking_data) do
    with :ok <- Prepare.validate_admission(booking_data),
         :ok <- validate_single_allowed(booking_data) do
      validate_time(booking_data, booking_data.organizer_user_id)
    end
  end

  # A type booked as a series takes no single sessions unless the host lets
  # it (`series_required: false`); a series is booked through
  # `Tymeslot.BookingSeries`. A reschedule moves one existing session and
  # never comes here.
  defp validate_single_allowed(%{meeting_type: %MeetingTypeSchema{} = type}) do
    if SeriesSettings.single_allowed?(type), do: :ok, else: {:error, :series_required}
  end

  defp validate_single_allowed(_booking_data), do: :ok

  # A fixed-date type offers only the sessions its host planned, so the time
  # booked must be one of them, still open for registration
  # (`Tymeslot.Meetings.PlannedSessions`). Its schedule, notice, booking
  # limits and the host's calendar play no part: the session is the host's
  # own plan, already on their calendar. A session that filled up has no join
  # target, so it is refused here as a lost race would be.
  #
  # This reads the session unlocked; `GroupScheduling.book_seat/3` reads its
  # registration close again under the row lock, so a booking validated just
  # before the close that commits after it is still refused.
  defp validate_time(booking_data, user_id) do
    if FixedDates.sessions?(Map.get(booking_data, :meeting_type)),
      do: validate_session(booking_data),
      else: validate_schedule_time(booking_data, user_id)
  end

  defp validate_session(booking_data) do
    case Map.get(booking_data, :join_target) do
      %{planned: true} = session ->
        if PlannedSessions.open?(session),
          do: {:ok, :validated},
          else: {:error, :slot_unavailable}

      _no_open_session ->
        {:error, :slot_unavailable}
    end
  end

  defp validate_schedule_time(booking_data, user_id) do
    config = scheduling_config(booking_data)

    # Time window validation
    with :ok <- Validation.validate_booking_time(booking_data.start_datetime, config),
         :ok <- validate_slot_on_schedule(booking_data, config),
         :ok <- validate_booking_limits(booking_data, user_id) do
      validate_calendar_availability(booking_data, config)
    end
  end

  # A direct load of `/:username/:slug/book` performs no step transition, so
  # none of the booking page's own guards on the offered slots ever run for
  # it. The schedule's windows and breaks are therefore re-derived here rather
  # than trusted from the submitted date and time. Conflicts are not this
  # check's business: `validate_calendar_availability/2` owns those.
  defp validate_slot_on_schedule(booking_data, config) do
    ScheduleCheck.validate_slot_on_schedule(
      booking_data.date,
      booking_data.start_datetime,
      booking_data.duration_minutes,
      booking_data.user_timezone,
      config,
      booking_data.organizer_user_id
    )
  end

  # Fast pre-check with a friendly error before any side-effect setup. The
  # race-safe check runs again inside the booking transaction
  # (Tymeslot.Meetings.Scheduling), because the page can go stale between
  # render and submit.
  #
  # A seat on a live group slot adds no meeting row, so it is not counted
  # against the limits and is exempt here. The exemption cannot be stretched
  # to a new slot: the seat transaction refuses a slot that filled up in the
  # meantime as full, and a slot cancelled in the meantime is recreated
  # through `Scheduling`, whose in-transaction limit check applies.
  defp validate_booking_limits(%{join_target: %{}}, _user_id), do: :ok

  defp validate_booking_limits(booking_data, user_id) do
    Checker.check_booking_allowed(
      user_id,
      Profiles.get_profile_settings(user_id),
      booking_data.meeting_type,
      booking_data.start_datetime
    )
  end

  # The refusal policy lives in `CalendarCheck.enforce/3`, shared with the
  # reschedule submit: a clash and an unreadable busy set both refuse (a clash
  # classifies as `:slot_taken`, returning the booker to the schedule step; an
  # unreadable busy set as `:availability_unverifiable`), while a transport
  # failure proceeds.
  defp validate_calendar_availability(booking_data, config) do
    case CalendarCheck.enforce(booking_data, config, calendar_check_opts(booking_data)) do
      :ok -> {:ok, :validated}
      {:error, reason} -> {:error, reason}
    end
  end

  # A seat on a live group slot adds no organiser busy time, so the slot's own
  # meeting event is excluded from the conflict check, exactly as a
  # reschedule excludes the meeting it moves. Only that one meeting is
  # excluded, and only when `CreateGroup.join_target/1` finds it joinable for
  # this booker's seats: a full slot keeps its event blocking and is refused
  # here, before any side effect, as the seat transaction would refuse it
  # (`:slot_full` -> `:slot_taken`). Every other event (other meetings,
  # external calendars) still refuses the booking.
  defp calendar_check_opts(booking_data) do
    [exclude: Map.get(booking_data, :join_target)]
  end

  defp create_meeting_and_all_side_effects_atomically(booking_data, opts) do
    meeting_attrs = MeetingAttributes.build(BuildParams.new(booking_data))

    cond do
      CreateGroup.applicable?(booking_data) ->
        CreateGroup.create(meeting_attrs, booking_data, opts)

      Prepare.paid?(booking_data) ->
        PaidBooking.create(meeting_attrs, booking_data,
          create_meeting: &Persist.create_meeting/1,
          create_guests: &Persist.create_guests/2,
          classify_error: &Errors.classify_creation_error(&1, booking_data),
          on_created: &Telemetry.booking_created/0
        )

      EmailVerification.required?(Map.get(booking_data, :meeting_type)) ->
        VerifiedBooking.create(meeting_attrs, booking_data,
          create_meeting: &Persist.create_meeting/1,
          create_guests: &Persist.create_guests/2,
          classify_error: &Errors.classify_creation_error(&1, booking_data)
        )

      true ->
        meeting_attrs
        |> run_meeting_transaction(booking_data, opts)
        |> map_transaction_result(booking_data)
    end
  end

  # The scheduling policy is derived from a profile lookup and a schedule
  # lookup. It is resolved once, in `validate_booking/2`, after the
  # meeting-type-active guard has passed (so an invalid type never pays for a
  # lookup it cannot use), and handed to the three checks that need it: the
  # booking window, the schedule's own slots and the calendar conflict check.
  defp scheduling_config(booking_data) do
    Schedules.booking_config(
      Map.get(booking_data, :organizer_user_id),
      Map.get(booking_data, :meeting_type)
    )
  end

  defp run_meeting_transaction(meeting_attrs, booking_data, opts) do
    Repo.transaction(fn ->
      # The emails, reminders and room job commit with the meeting, so a
      # booking that loses its slot leaves none behind, and a booking whose
      # emails cannot be queued is not made; the integration fan-out waits
      # for the commit (`Activation.activate_in_transaction/2`).
      case Persist.persist_and_activate(meeting_attrs, booking_data, opts) do
        {:ok, meeting_and_pending} -> meeting_and_pending
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp map_transaction_result({:ok, {meeting, pending_integrations}}, _booking_data) do
    :ok = Activation.after_commit(pending_integrations)
    Availability.changed(meeting.organizer_user_id)
    Telemetry.booking_created()
    {:ok, meeting}
  end

  defp map_transaction_result({:error, reason}, booking_data),
    do: {:error, Errors.classify_creation_error(reason, booking_data)}
end
