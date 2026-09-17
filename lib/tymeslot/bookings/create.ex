defmodule Tymeslot.Bookings.Create do
  @moduledoc """
  Orchestrates the booking creation process.
  Combines validation, policy enforcement, and side effects.
  """

  require Logger

  alias Tymeslot.Availability.Offer

  alias Tymeslot.Bookings.{
    Activation,
    BuildParams,
    CalendarCheck,
    CalendarJobs,
    Errors,
    Policy,
    ScheduleCheck,
    Validation
  }

  alias Tymeslot.Bookings.Create.PaidBooking
  alias Tymeslot.CustomFields
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Locales
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Scheduling.SharedAvailability
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
  Result returned by `execute/3` and `execute_with_video_room/3`.

  The domain layer classifies every failure reason into one of
  `Tymeslot.Bookings.Errors.classified_error/0` (or, for reasons that
  already arrive as arbitrary changeset/validation text, passes the binary
  through unchanged). Rendering an atom to user-facing copy is entirely the
  web layer's responsibility — see
  `TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage`.
  """
  @type execute_result ::
          {:ok, map()}
          | {:ok, :payment_required, %{meeting: map(), checkout_url: String.t()}}
          | {:error, Errors.classified_error() | String.t()}

  @doc """
  Creates a booking with fresh calendar validation.

  This is the main entry point for creating bookings.

  Options:
    - :skip_calendar_check - Skip calendar availability validation
    - :with_video_room - Create with video room integration

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
         {:ok, :validated} <- validate_booking(booking_data, opts) do
      create_meeting_and_all_side_effects_atomically(booking_data, opts)
    else
      {:error, reason} -> {:error, classify_error(reason)}
    end
  end

  @doc """
  Creates a booking with video room integration.

  Includes optional calendar pre-check for better UX.
  Same options as execute/3 plus video room is automatically enabled.
  """
  @spec execute_with_video_room(meeting_params(), form_data(), keyword()) :: execute_result()
  def execute_with_video_room(meeting_params, form_data, opts \\ []) do
    opts = Keyword.put(opts, :with_video_room, true)

    with {:ok, booking_data} <- prepare_booking_data(meeting_params, form_data),
         :ok <- validate_custom_field_answers(booking_data) do
      booking_data = put_scheduling_config(booking_data)
      config = scheduling_config(booking_data)

      # Try calendar pre-check for better UX
      case CalendarCheck.probe(booking_data, config) do
        :ok ->
          # Calendar shows available, proceed normally
          execute_internal(booking_data, form_data, opts)

        {:error, :slot_unavailable} ->
          # Fail fast for better UX
          {:error, classify_error(:slot_unavailable)}

        {:error, _reason} ->
          # Calendar check failed, but continue with atomic booking
          execute_internal(booking_data, form_data, opts)
      end
    else
      {:error, reason} -> {:error, classify_error(reason)}
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
    meeting_type = resolve_meeting_type_for_duration(meeting_params)
    duration_minutes = Offer.duration_minutes(meeting_type, meeting_params.duration)

    with {:ok, shared_availability_guests} <- resolve_shared_availability_guests(meeting_params),
         {:ok, date_string} <- normalize_date_input(meeting_params.date),
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
        attendee_locale: Map.get(meeting_params, :attendee_locale) || default_locale(),
        custom_fields_snapshot: Map.get(meeting_params, :custom_fields_snapshot, []),
        custom_field_answers: Map.get(meeting_params, :custom_field_answers, %{}),
        guest_emails: Map.get(meeting_params, :guest_emails, []),
        shared_availability_guests: shared_availability_guests,
        utm_source: Map.get(meeting_params, :utm_source),
        utm_medium: Map.get(meeting_params, :utm_medium),
        utm_campaign: Map.get(meeting_params, :utm_campaign),
        utm_content: Map.get(meeting_params, :utm_content),
        utm_term: Map.get(meeting_params, :utm_term),
        referrer_host: Map.get(meeting_params, :referrer_host),
        tracking_params: Map.get(meeting_params, :tracking_params, %{}),
        visitor_hash: Map.get(meeting_params, :visitor_hash)
      }

      {:ok, booking_data}
    else
      {:error, :invalid_date_input} -> {:error, "Invalid date format"}
      {:error, :invalid_format} -> {:error, "Invalid date format"}
      error -> error
    end
  end

  defp default_locale, do: Locales.booking_default_locale()

  # The users named in the booking link (`?with=`) are resolved again here from
  # their usernames rather than trusted from the page, which may have gone
  # stale: one of them could have lost their public page since it rendered.
  defp resolve_shared_availability_guests(meeting_params) do
    case {Map.get(meeting_params, :shared_availability_usernames, []),
          Map.get(meeting_params, :organizer_user_id)} do
      {[], _organizer_user_id} ->
        {:ok, []}

      {usernames, organizer_user_id} when is_list(usernames) and is_integer(organizer_user_id) ->
        SharedAvailability.resolve(usernames, organizer_user_id)

      _unresolvable ->
        {:error, :unavailable_guests}
    end
  end

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

  defp validate_booking(booking_data, opts) do
    # Get organizer user_id from booking data - now required
    organizer_user_id = Map.get(booking_data, :organizer_user_id)

    case organizer_user_id do
      nil ->
        {:error, :organizer_required}

      user_id ->
        # Meeting type active check
        with :ok <- validate_meeting_type_active(booking_data),
             :ok <- validate_payments_available(booking_data, user_id) do
          config = scheduling_config(booking_data)

          # Time window validation
          with :ok <-
                 Validation.validate_booking_time(
                   booking_data.start_datetime,
                   booking_data.user_timezone,
                   config
                 ),
               :ok <- validate_slot_on_schedule(booking_data, config),
               :ok <- validate_shared_availability_guests_allowed(booking_data),
               :ok <- validate_booking_limits(booking_data, user_id) do
            validate_availability(booking_data, config, opts)
          end
        end
    end
  end

  # Optional fresh calendar validation, for the host and then for every user
  # named in the booking link.
  defp validate_availability(booking_data, config, opts) do
    if Keyword.get(opts, :skip_calendar_check, false) do
      validate_shared_availability(booking_data, config, &guest_events_without_calendar/2)
    else
      with {:ok, :validated} <- validate_calendar_availability(booking_data, config) do
        validate_shared_availability(
          booking_data,
          config,
          SharedAvailability.fresh_events_fetcher()
        )
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
  defp validate_payments_available(booking_data, user_id) do
    if paid_meeting_type?(booking_data) and
         not MeetingPayments.charges_enabled_for_user?(user_id) do
      {:error, :payments_unavailable}
    else
      :ok
    end
  end

  # Users named in the link join as guests, so a meeting type without guests
  # cannot take them. The booking page already refuses such a type; this is
  # the server-side half of that rule.
  defp validate_shared_availability_guests_allowed(
         %{shared_availability_guests: [_first | _rest]} = data
       ) do
    if guests_allowed?(data), do: :ok, else: {:error, :unavailable_guests}
  end

  defp validate_shared_availability_guests_allowed(_booking_data), do: :ok

  # Every user named in the link has to be free as well: on their own schedule,
  # in their calendar and in the bookings they host. A guest's calendar that
  # cannot be read is treated exactly like the host's in
  # `validate_calendar_availability/2`: a conflict or an incomplete busy set
  # refuses, a transport failure lets the booking through.
  defp validate_shared_availability(%{shared_availability_guests: []}, _config, _fetcher),
    do: {:ok, :validated}

  defp validate_shared_availability(booking_data, config, fetcher) do
    case SharedAvailability.validate_guests_available(
           booking_data.shared_availability_guests,
           booking_data.date,
           booking_data.start_datetime,
           booking_data.end_datetime,
           booking_data.user_timezone,
           config,
           fetcher
         ) do
      :ok ->
        {:ok, :validated}

      {:error, :slot_unavailable} ->
        {:error, :slot_unavailable}

      {:error, reason} when reason in [:some_calendars_unavailable, :all_calendars_unavailable] ->
        {:error, :availability_unverifiable}

      {:error, reason} ->
        Logger.warning(
          "Guest calendar availability check failed, proceeding with booking",
          reason: inspect(reason),
          organizer_user_id: booking_data.organizer_user_id
        )

        {:ok, :validated}
    end
  end

  # With the calendar check skipped, a guest's schedule and hosted bookings are
  # still checked; only their calendar is left out, as the host's is.
  defp guest_events_without_calendar(_guest, _date), do: {:ok, []}

  # Fast pre-check with a friendly error before any side-effect setup. The
  # race-safe check runs again inside the booking transaction
  # (Tymeslot.Meetings.Scheduling), because the page can go stale between
  # render and submit.
  defp validate_booking_limits(booking_data, user_id) do
    Checker.check_booking_allowed(
      user_id,
      Profiles.get_profile_settings(user_id),
      booking_data.meeting_type,
      booking_data.start_datetime
    )
  end

  # The refusal policy lives in `CalendarCheck.enforce/3`, shared with the
  # reschedule submit: a clash and an unreadable busy set both refuse (and
  # `classify_error/1` collapses either to `:slot_taken`, returning the booker
  # to the schedule step), while a transport failure proceeds.
  defp validate_calendar_availability(booking_data, config) do
    case CalendarCheck.enforce(booking_data, config) do
      :ok -> {:ok, :validated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_internal(booking_data, _form_data, opts) do
    case validate_booking(booking_data, opts) do
      {:ok, :validated} ->
        create_meeting_and_all_side_effects_atomically(booking_data, opts)

      {:error, reason} ->
        {:error, classify_error(reason)}
    end
  end

  defp create_meeting_and_all_side_effects_atomically(booking_data, opts) do
    meeting_attrs = Policy.build_meeting_attributes(BuildParams.new(booking_data))

    if paid_meeting_type?(booking_data) do
      PaidBooking.create(meeting_attrs, booking_data,
        create_meeting: &create_meeting/1,
        create_guests: &create_guests/2,
        classify_error: &classify_error/1,
        on_created: &emit_booking_created/0
      )
    else
      meeting_attrs
      |> run_meeting_transaction(booking_data, opts)
      |> map_transaction_result()
    end
  end

  # The scheduling policy is derived from a profile lookup and a schedule
  # lookup, and three separate checks need it: the booking window, the
  # schedule's own slots, and the calendar conflict check. `execute_with_video_room/3`
  # needs it ahead of `validate_booking/2` for its calendar pre-check, so it
  # resolves eagerly here; `execute/3` has no such early need and instead lets
  # `validate_booking/2` resolve it lazily via `scheduling_config/1`, once the
  # meeting-type-active guard has passed, so an invalid meeting type never
  # pays for a profile/schedule lookup it can't use.
  defp put_scheduling_config(booking_data) do
    Map.put_new_lazy(booking_data, :scheduling_config, fn ->
      derive_scheduling_config(booking_data)
    end)
  end

  defp scheduling_config(booking_data) do
    Map.get_lazy(booking_data, :scheduling_config, fn ->
      derive_scheduling_config(booking_data)
    end)
  end

  defp derive_scheduling_config(booking_data) do
    booking_data
    |> Map.get(:organizer_user_id)
    |> Policy.scheduling_config(Map.get(booking_data, :meeting_type))
    |> SharedAvailability.strictest_policy(Map.get(booking_data, :shared_availability_guests, []))
  end

  defp paid_meeting_type?(%{meeting_type: %{payment_required: true}}), do: true
  defp paid_meeting_type?(_other), do: false

  defp run_meeting_transaction(meeting_attrs, booking_data, opts) do
    Repo.transaction(fn ->
      with {:ok, meeting} <- create_meeting(meeting_attrs),
           {:ok, _guests} <- create_guests(meeting, booking_data),
           {:ok, _result} <- schedule_calendar_job(meeting) do
        # Post-creation side effects (emails/video) are now part of the transaction
        # This ensures that if meeting creation fails due to a race condition (unique index),
        # no side-effect jobs (Oban) are committed.
        Activation.activate(meeting, opts)
        meeting
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
    if guests_allowed?(booking_data) do
      booking_data
      |> Map.get(:shared_availability_guests, [])
      |> SharedAvailability.merge_guest_emails(Map.get(booking_data, :guest_emails, []))
      |> Guests.sanitize_emails(meeting.attendee_email)
      |> then(&Guests.create_for_meeting(meeting.id, &1))
    else
      {:ok, []}
    end
  end

  defp guests_allowed?(%{meeting_type: %{allow_guests: true}}), do: true
  defp guests_allowed?(_booking_data), do: false

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

  defp map_transaction_result({:ok, meeting}) do
    AvailabilityCache.invalidate_for_user(meeting.organizer_user_id)
    emit_booking_created()
    {:ok, meeting}
  end

  defp map_transaction_result({:error, reason}), do: {:error, classify_error(reason)}

  # Classifies every failure reason into a semantic atom rather than a
  # display string, so callers can dispatch on the error's identity (e.g.
  # bounce the booker back to the schedule step on `:slot_taken`) without
  # depending on copy text. The web layer owns rendering these atoms to
  # user-facing messages. `:time_conflict` and `:slot_unavailable` both
  # describe the same lost-race outcome and collapse to `:slot_taken`;
  # `:host_not_found`/`:host_missing` and `:meeting_type_not_found`/
  # `:meeting_type_missing` are likewise distinct upstream reasons that
  # share one user-facing meaning, so they collapse to a single atom each.
  # Reasons that already arrive as arbitrary changeset/validation text pass
  # through unchanged (`is_binary/1` clause).
  # A table rather than a clause ladder: every entry is the same behaviour over
  # varying data, so the mapping is the whole content. `:availability_unverifiable`
  # collapses to `:slot_taken` because we could not read the organiser's full busy
  # set and so cannot prove the slot is free — the booker gets the same "pick
  # another slot" outcome as a genuine clash, and the distinction survives in the
  # logs rather than the copy. `ScheduleCheck`'s own reasons
  # (`:slot_not_offered`, `:slot_availability_unverifiable`) are deliberately
  # absent here: they are classified once, in `Errors.classify_schedule_check_reason/1`,
  # shared with `Reschedule`, rather than duplicated in this table.
  @error_classifications %{
    meeting_type_inactive: :meeting_type_inactive,
    meeting_type_not_found: :meeting_type_not_found,
    meeting_type_missing: :meeting_type_not_found,
    time_conflict: :slot_taken,
    slot_unavailable: :slot_taken,
    availability_unverifiable: :slot_taken,
    booking_limit_reached: :booking_limit_reached,
    organizer_required: :organizer_required,
    validation_error: :booking_failed,
    payments_unavailable: :payments_unavailable,
    host_not_found: :host_not_found,
    host_missing: :host_not_found,
    unavailable_guests: :booking_failed
  }

  defp classify_error(reason) when is_map_key(@error_classifications, reason),
    do: Map.fetch!(@error_classifications, reason)

  defp classify_error({:custom_field_errors, _errors}), do: :custom_field_errors
  defp classify_error({:checkout_failed, _reason}), do: :checkout_failed

  defp classify_error(reason) when is_atom(reason) do
    Errors.classify_schedule_check_reason(reason) || :booking_failed
  end

  defp classify_error(reason) when is_binary(reason), do: reason
  defp classify_error(_other), do: :booking_failed

  defp emit_booking_created do
    :telemetry.execute([:tymeslot, :booking, :created], %{count: 1}, %{})
  end
end
