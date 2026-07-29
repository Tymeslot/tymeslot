defmodule Tymeslot.Bookings.Create do
  @moduledoc """
  Orchestrates the booking creation process.
  Combines validation, policy enforcement, and side effects.
  """

  require Logger

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{BuildParams, CalendarJobs, Errors, Policy, Validation}
  alias Tymeslot.CustomFields
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig
  alias Tymeslot.Locales
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Meetings.Guests
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoRoomWorker
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
      # Try calendar pre-check for better UX
      case fresh_calendar_check(booking_data) do
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
    with {:ok, date_string} <- normalize_date_input(meeting_params.date),
         {:ok, {start_datetime, end_datetime}} <-
           Validation.parse_meeting_times(
             date_string,
             meeting_params.time,
             meeting_params.duration,
             meeting_params.user_timezone
           ),
         {:ok, date} <- Date.from_iso8601(date_string) do
      meeting_uid = UUID.uuid4()

      duration_minutes = TimeSlots.parse_duration(meeting_params.duration)

      booking_data = %{
        meeting_uid: meeting_uid,
        start_datetime: start_datetime,
        end_datetime: end_datetime,
        duration_minutes: duration_minutes,
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

  defp default_locale, do: Locales.default_locale()

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
        with :ok <- validate_meeting_type_active(booking_data, user_id) do
          config = Policy.scheduling_config(user_id)

          # Time window validation
          with :ok <-
                 Validation.validate_booking_time(
                   booking_data.start_datetime,
                   booking_data.user_timezone,
                   config
                 ) do
            # Optional fresh calendar validation
            if Keyword.get(opts, :skip_calendar_check, false) do
              {:ok, :validated}
            else
              validate_calendar_availability(booking_data, config)
            end
          end
        end
    end
  end

  defp validate_meeting_type_active(%{meeting_type_id: nil}, _user_id), do: :ok

  defp validate_meeting_type_active(%{meeting_type_id: type_id}, user_id) do
    alias Tymeslot.MeetingTypes

    case MeetingTypes.get_meeting_type(type_id, user_id) do
      %{is_active: true} -> :ok
      %{is_active: false} -> {:error, :meeting_type_inactive}
      nil -> {:error, :meeting_type_not_found}
    end
  end

  defp validate_calendar_availability(booking_data, _config) do
    case fresh_calendar_check(booking_data) do
      :ok ->
        {:ok, :validated}

      {:error, :slot_unavailable} ->
        # Actual conflict detected - fail fast to prevent double booking
        {:error, :slot_unavailable}

      {:error, reason} ->
        # Calendar transport/timeout errors - log but don't block booking
        # The booking will succeed and calendar sync will be retried in background
        Logger.warning(
          "Calendar availability check failed, proceeding with booking",
          reason: inspect(reason),
          organizer_user_id: booking_data.organizer_user_id
        )

        {:ok, :validated}
    end
  end

  defp fresh_calendar_check(booking_data) do
    %{start_datetime: start_datetime, end_datetime: end_datetime, date: date} = booking_data

    case Map.get(booking_data, :organizer_user_id) do
      nil ->
        {:error, :organizer_required}

      organizer_user_id ->
        # Use a short timeout for booking-time calendar checks (5 seconds)
        # Availability was already validated when slots were displayed, so we don't
        # want to block the user if calendar is slow. If it times out, we proceed anyway.
        check_task =
          Task.Supervisor.async(Tymeslot.TaskSupervisor, fn ->
            CalendarEvents.get_events_for_range_fresh(organizer_user_id, date, date)
          end)

        case Task.yield(check_task, 5_000) || Task.shutdown(check_task) do
          {:ok, {:ok, events}} ->
            Validation.validate_no_conflicts(
              start_datetime,
              end_datetime,
              events,
              Policy.scheduling_config(organizer_user_id)
            )

          {:ok, {:error, reason}} ->
            {:error, reason}

          nil ->
            # Task timed out - log and return timeout error
            Logger.warning(
              "Calendar availability check timed out after 5s, proceeding with booking",
              organizer_user_id: organizer_user_id
            )

            {:error, :timeout}
        end
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
    booking_data = put_meeting_type_record(booking_data)
    meeting_attrs = Policy.build_meeting_attributes(BuildParams.new(booking_data))

    if paid_meeting_type?(booking_data) do
      create_paid_booking(meeting_attrs, booking_data)
    else
      meeting_attrs
      |> run_meeting_transaction(booking_data, opts)
      |> map_transaction_result()
    end
  end

  # Resolves the meeting-type record once up front and stashes it on
  # `booking_data`, so the paid? and guests-allowed? predicates (the latter
  # running inside the booking transaction) read it from memory instead of each
  # issuing its own identical query.
  defp put_meeting_type_record(%{meeting_type_id: nil} = booking_data) do
    Map.put(booking_data, :meeting_type, nil)
  end

  defp put_meeting_type_record(
         %{meeting_type_id: type_id, organizer_user_id: user_id} = booking_data
       )
       when is_integer(user_id) do
    Map.put(booking_data, :meeting_type, MeetingTypes.get_meeting_type(type_id, user_id))
  end

  defp put_meeting_type_record(booking_data), do: Map.put(booking_data, :meeting_type, nil)

  defp paid_meeting_type?(%{meeting_type: %{payment_required: true}}), do: true
  defp paid_meeting_type?(_other), do: false

  defp create_paid_booking(meeting_attrs, booking_data) do
    paid_attrs = Map.put(meeting_attrs, :status, "awaiting_payment")

    # The Stripe checkout call deliberately runs OUTSIDE any DB transaction:
    # holding a pooled DB connection open across a network round-trip to Stripe
    # risks pool exhaustion under Stripe slowness. The meeting is created (and
    # conflict-checked) atomically first; the Stripe call follows.
    #
    # On checkout failure we expire the just-created meeting so its slot is
    # released immediately rather than waiting on the reconciliation sweep —
    # the sweeper remains the net for failures we cannot observe here (e.g. a
    # crash between session creation and the client redirect).
    #
    # Guest insertion runs after the meeting is committed, so on guest failure
    # we also expire the meeting immediately rather than leaving an orphaned
    # awaiting_payment record holding the slot until the reconciliation sweep.
    case create_meeting(paid_attrs) do
      {:ok, meeting} ->
        case create_guests(meeting, booking_data) do
          {:ok, _guests} ->
            case create_checkout_or_expire(meeting) do
              {:ok, %{checkout_url: url}} ->
                emit_booking_created()
                {:ok, :payment_required, %{meeting: meeting, checkout_url: url}}

              {:error, reason} ->
                {:error, classify_error(reason)}
            end

          {:error, reason} ->
            expire_unpaid_meeting(meeting, reason)
            {:error, classify_error(reason)}
        end

      {:error, reason} ->
        {:error, classify_error(reason)}
    end
  end

  defp create_checkout_or_expire(meeting) do
    case MeetingPayments.create_checkout_session(meeting) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        expire_unpaid_meeting(meeting, reason)
        {:error, {:checkout_failed, reason}}
    end
  end

  defp expire_unpaid_meeting(meeting, reason) do
    case Scheduling.update_meeting_with_conflict_check(meeting, %{status: "expired"}) do
      {:ok, _expired} ->
        :ok

      {:error, expire_error} ->
        Logger.warning("Failed to expire meeting after checkout failure",
          meeting_id: meeting.id,
          checkout_error: inspect(reason),
          expire_error: inspect(expire_error)
        )

        :ok
    end
  end

  defp run_meeting_transaction(meeting_attrs, booking_data, opts) do
    Repo.transaction(fn ->
      with {:ok, meeting} <- create_meeting(meeting_attrs),
           {:ok, _guests} <- create_guests(meeting, booking_data),
           {:ok, _result} <- schedule_calendar_job(meeting) do
        # Post-creation side effects (emails/video) are now part of the transaction
        # This ensures that if meeting creation fails due to a race condition (unique index),
        # no side-effect jobs (Oban) are committed.
        handle_post_creation_effects(meeting, opts)
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
      |> Map.get(:guest_emails, [])
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
  defp classify_error(reason) do
    case reason do
      :meeting_type_inactive ->
        :meeting_type_inactive

      :meeting_type_not_found ->
        :meeting_type_not_found

      :time_conflict ->
        :slot_taken

      :slot_unavailable ->
        :slot_taken

      :organizer_required ->
        :organizer_required

      :validation_error ->
        :booking_failed

      :payments_unavailable ->
        :payments_unavailable

      :host_not_found ->
        :host_not_found

      :host_missing ->
        :host_not_found

      :meeting_type_missing ->
        :meeting_type_not_found

      {:custom_field_errors, _errors} ->
        :custom_field_errors

      {:checkout_failed, _reason} ->
        :checkout_failed

      reason when is_binary(reason) ->
        reason

      _other ->
        :booking_failed
    end
  end

  defp emit_booking_created do
    :telemetry.execute([:tymeslot, :booking, :created], %{count: 1}, %{})
  end

  defp handle_post_creation_effects(meeting, opts) do
    # Calendar job was scheduled atomically with meeting creation

    # If explicitly requested, create video room first when a provider is configured
    if Keyword.get(opts, :with_video_room, false) do
      if meeting.video_integration_id do
        schedule_video_room_with_emails(meeting)
      else
        # No video provider configured, skip video job
        schedule_email_notifications(meeting)
      end
    else
      # Auto-detect: if the meeting has a specific video provider configured that supports
      # API-based room creation, create the video room before sending emails so the email
      # includes the join link.
      case video_provider_for(meeting) do
        {:ok, provider} when provider in [:mirotalk, :google_meet, :teams, :custom] ->
          schedule_video_room_with_emails(meeting)

        _other ->
          # No supported auto-create provider (none/unknown/etc.)
          schedule_email_notifications(meeting)
      end
    end
  end

  defp schedule_video_room_with_emails(meeting) do
    case VideoRoomWorker.schedule_video_room_creation_with_emails(meeting.id) do
      :ok ->
        :ok

      {:error, _reason} ->
        # Fall back to email only
        schedule_email_notifications(meeting)
        :ok
    end
  end

  defp schedule_email_notifications(meeting) do
    alias Tymeslot.Notifications.Events

    case Events.meeting_created(meeting) do
      {:ok, _result} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule confirmation emails for meeting",
          meeting_id: meeting.id,
          error: inspect(reason)
        )

        :ok
    end
  end

  defp video_provider_for(meeting) do
    integration_result =
      case meeting.video_integration_id do
        nil -> {:error, :not_found}
        id -> Video.fetch_integration_for_user(id, meeting.organizer_user_id)
      end

    case integration_result do
      {:ok, integration} ->
        # Convert stored provider string (e.g., "google_meet") to atom if known
        provider =
          case VideoProviderConfig.parse_known(integration.provider) do
            {:ok, provider} ->
              provider

            {:error, :unknown} ->
              Logger.warning("Video integration has an unrecognised provider",
                video_integration_id: meeting.video_integration_id,
                provider: integration.provider
              )

              :none
          end

        {:ok, provider}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
