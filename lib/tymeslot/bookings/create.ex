defmodule Tymeslot.Bookings.Create do
  @moduledoc """
  Orchestrates the booking creation process.
  Combines validation, policy enforcement, and side effects.
  """

  alias Tymeslot.Auth
  alias Tymeslot.Availability
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.Schedules

  alias Tymeslot.Bookings.{
    Activation,
    BuildParams,
    CalendarCheck,
    CalendarJobs,
    CreateGroup,
    Errors,
    MeetingAttributes,
    Policy,
    ScheduleCheck,
    Validation
  }

  alias Tymeslot.Bookings.Create.PaidBooking
  alias Tymeslot.Bookings.Telemetry
  alias Tymeslot.CustomFields
  alias Tymeslot.Locales
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias UUID

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
          | {:ok, :payment_required, %{meeting: map(), checkout_url: String.t()}}
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
  is persisted with status `awaiting_payment`, side effects (calendar, video,
  email) are deferred until payment confirmation, and a Stripe Checkout
  Session URL is returned alongside the meeting via the
  `{:ok, :payment_required, ...}` tuple.
  """
  @spec execute(meeting_params(), form_data(), keyword()) :: execute_result()
  def execute(meeting_params, form_data, opts \\ []) do
    with {:ok, booking_data} <- prepare_booking_data(meeting_params, form_data),
         :ok <- validate_custom_field_answers(booking_data),
         {:ok, :validated} <- validate_booking(booking_data) do
      create_meeting_and_all_side_effects_atomically(booking_data, opts)
    else
      {:error, reason} -> {:error, Errors.classify_error(reason)}
    end
  end

  # Private functions

  defp validate_custom_field_answers(%{
         custom_fields_snapshot: snapshot,
         custom_field_answers: answers
       }) do
    case CustomFields.validate_answers(snapshot, answers) do
      {:ok, _normalised} -> :ok
      {:error, errors} -> {:error, {:custom_field_errors, errors}}
    end
  end

  defp prepare_booking_data(meeting_params, form_data) do
    # The duration used to compute the slot and to gate ScheduleCheck's
    # granularity comes from the resolved meeting type, never the request,
    # whenever a type is known — mirroring Reschedule, which pins duration to
    # the persisted meeting rather than trusting `params.duration`. Only an
    # unresolvable type (ad-hoc booking, or one that fails
    # `validate_meeting_type_active/1` a few steps later) falls back to the
    # client-supplied value, bounded exactly as the booking page bounds it.
    # Resolving here also stashes the record on `booking_data` for everything
    # downstream: the group join lookup needs it to know whether this is a
    # group booking (see `CreateGroup.join_target/1`), and the active/limits validations
    # and the paid?/guests-allowed? predicates then read it from memory instead
    # of each issuing the same query again.
    meeting_type = resolve_meeting_type_for_duration(meeting_params)
    duration_minutes = Offer.duration_minutes(meeting_type, meeting_params.duration)

    with {:ok, date_string} <- normalize_date_input(meeting_params.date),
         {:ok, {start_datetime, end_datetime}} <-
           Validation.parse_meeting_times(
             date_string,
             meeting_params.time,
             duration_minutes,
             meeting_params.user_timezone
           ),
         {:ok, date} <- Date.from_iso8601(date_string) do
      meeting_uid = UUID.uuid4()

      booking_data = %{
        meeting_uid: meeting_uid,
        start_datetime: start_datetime,
        end_datetime: end_datetime,
        duration_minutes: duration_minutes,
        meeting_type: meeting_type,
        user_timezone: meeting_params.user_timezone,
        form_data: form_data,
        date: date,
        organizer_user_id: Map.get(meeting_params, :organizer_user_id),
        meeting_type_id: Map.get(meeting_params, :meeting_type_id),
        video_integration_id: Map.get(meeting_params, :video_integration_id),
        location_option_id: Map.get(meeting_params, :location_option_id),
        location_phone: Map.get(meeting_params, :location_phone),
        location_video_integration_id: Map.get(meeting_params, :location_video_integration_id),
        location_venue_id: Map.get(meeting_params, :location_venue_id),
        attendee_locale: Map.get(meeting_params, :attendee_locale) || default_locale(),
        custom_fields_snapshot: Map.get(meeting_params, :custom_fields_snapshot, []),
        custom_field_answers: Map.get(meeting_params, :custom_field_answers, %{}),
        guest_emails: Map.get(meeting_params, :guest_emails, []),
        utm_source: Map.get(meeting_params, :utm_source),
        utm_medium: Map.get(meeting_params, :utm_medium),
        utm_campaign: Map.get(meeting_params, :utm_campaign),
        utm_content: Map.get(meeting_params, :utm_content),
        utm_term: Map.get(meeting_params, :utm_term),
        referrer_host: Map.get(meeting_params, :referrer_host),
        tracking_params: Map.get(meeting_params, :tracking_params, %{}),
        visitor_hash: Map.get(meeting_params, :visitor_hash)
      }

      # Read once, here, so the booking-limit pre-check and the calendar
      # check agree on whether this booking joins a live group slot.
      {:ok, Map.put(booking_data, :join_target, CreateGroup.join_target(booking_data))}
    else
      {:error, :invalid_date_input} -> {:error, :invalid_datetime}
      {:error, :invalid_format} -> {:error, :invalid_datetime}
      error -> error
    end
  end

  defp default_locale, do: Locales.booking_default_locale()

  defp resolve_meeting_type_for_duration(meeting_params) do
    type_id = Map.get(meeting_params, :meeting_type_id)
    user_id = Map.get(meeting_params, :organizer_user_id)

    if is_integer(type_id) and is_integer(user_id) do
      MeetingTypes.get_meeting_type(type_id, user_id)
    end
  end

  defp normalize_date_input(%Date{} = date), do: {:ok, Date.to_iso8601(date)}
  defp normalize_date_input(date) when is_binary(date), do: {:ok, date}
  defp normalize_date_input(_arg), do: {:error, :invalid_date_input}

  # A host whose account waits to be deleted takes no new bookings, even from
  # a booking page that was already open when the deletion was requested.
  defp validate_host_accepting(user_id) do
    if Auth.deletion_pending?(user_id), do: {:error, :host_not_found}, else: :ok
  end

  defp validate_booking(booking_data) do
    # Get organizer user_id from booking data - now required
    organizer_user_id = Map.get(booking_data, :organizer_user_id)

    case organizer_user_id do
      nil ->
        {:error, :organizer_required}

      user_id ->
        # Meeting type active check
        with :ok <- validate_host_accepting(user_id),
             :ok <- validate_meeting_type_active(booking_data),
             :ok <- CreateGroup.ensure_taking_seats(booking_data),
             :ok <- validate_payments_available(booking_data, user_id) do
          config = scheduling_config(booking_data)

          # Time window validation
          with :ok <-
                 Validation.validate_booking_time(booking_data.start_datetime, config),
               :ok <- validate_slot_on_schedule(booking_data, config),
               :ok <- validate_booking_limits(booking_data, user_id) do
            validate_calendar_availability(booking_data, config)
          end
        end
    end
  end

  # Reads the record resolved by resolve_meeting_type_for_duration/1 (called
  # from prepare_booking_data/2) — a nil record with a meeting_type_id set
  # means the type doesn't exist (or belongs to another host).
  defp validate_meeting_type_active(%{meeting_type_id: nil}), do: :ok
  defp validate_meeting_type_active(%{meeting_type: %{is_active: true}}), do: :ok

  defp validate_meeting_type_active(%{meeting_type: %{is_active: false}}),
    do: {:error, :meeting_type_inactive}

  defp validate_meeting_type_active(%{meeting_type: nil}), do: {:error, :meeting_type_not_found}

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

  # A paid meeting type outlives its host's Stripe connection: the price is
  # kept so it resumes when they reconnect, rather than being cleared behind
  # their back. Refusing here is what stops the booking being taken anyway:
  # without it the meeting was created in `awaiting_payment`, `CheckoutSessions`
  # then refused for want of a charges-enabled account, and the booker was left
  # with the same message on top of a half-made booking that had to expire.
  # The same holds when the host's plan no longer grants payments.
  defp validate_payments_available(booking_data, user_id) do
    if paid_meeting_type?(booking_data) and
         not MeetingPayments.accepting_payments?(user_id) do
      {:error, :payments_unavailable}
    else
      :ok
    end
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

      paid_meeting_type?(booking_data) ->
        PaidBooking.create(meeting_attrs, booking_data,
          create_meeting: &create_meeting/1,
          create_guests: &create_guests/2,
          classify_error: &Errors.classify_creation_error(&1, booking_data),
          on_created: &Telemetry.booking_created/0
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

  defp paid_meeting_type?(%{meeting_type: %{payment_required: true}}), do: true
  defp paid_meeting_type?(_other), do: false

  defp run_meeting_transaction(meeting_attrs, booking_data, opts) do
    Repo.transaction(fn ->
      # The emails, reminders and room job commit with the meeting, so a
      # booking that loses its slot leaves none behind, and a booking whose
      # emails cannot be queued is not made; the integration fan-out waits
      # for the commit (`Activation.activate_in_transaction/2`).
      with {:ok, meeting} <- create_meeting(meeting_attrs),
           {:ok, _guests} <- create_guests(meeting, booking_data),
           {:ok, _result} <- schedule_calendar_job(meeting),
           {:ok, pending} <- Activation.activate_in_transaction(meeting, opts) do
        {meeting, pending}
      else
        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # Persists the attendee-added guests, but only when the meeting type allows
  # guests. Sanitisation (format, de-dup, self-exclusion, cap) is re-applied
  # here server-side — the client list is never trusted. Runs inside the
  # booking transaction so a guest failure rolls the whole booking back.
  defp create_guests(meeting, booking_data) do
    if Policy.guests_allowed?(booking_data) do
      booking_data
      |> Map.get(:guest_emails, [])
      |> Guests.sanitize_emails(meeting.attendee_email)
      |> then(&Guests.create_for_meeting(meeting.id, &1, :booker))
    else
      {:ok, []}
    end
  end

  defp create_meeting(meeting_attrs) do
    case Scheduling.create_meeting_with_conflict_check(meeting_attrs) do
      {:ok, meeting} -> {:ok, meeting}
      {:error, :time_conflict} -> {:error, :time_conflict}
      {:error, {:validation_error, _changeset}} -> {:error, :validation_error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schedule_calendar_job(meeting) do
    CalendarJobs.schedule_job(meeting, "create")
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
