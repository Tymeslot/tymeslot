defmodule Tymeslot.Bookings.Create do
  @moduledoc """
  Orchestrates the booking creation process.
  Combines validation, policy enforcement, and side effects.
  """

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Bookings.{CalendarJobs, Policy, Validation}
  alias Tymeslot.DatabaseQueries.VideoIntegrationQueries
  alias Tymeslot.Meetings.Scheduling
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoRoomWorker
  alias UUID

  @type meeting_params :: map()
  @type form_data :: map()
  @type booking_data :: map()

  @type error_reason :: String.t() | atom() | {:validation_error, any()}

  # Get Calendar module dynamically to allow mocking in tests
  defp calendar_module do
    Application.get_env(
      :tymeslot,
      :calendar_module,
      Tymeslot.Integrations.Calendar
    )
  end

  @doc """
  Creates a booking with fresh calendar validation.

  This is the main entry point for creating bookings.

  Options:
    - :skip_calendar_check - Skip calendar availability validation
    - :with_video_room - Create with video room integration
  """
  @spec execute(meeting_params(), form_data(), keyword()) ::
          {:ok, map()} | {:error, error_reason()}
  def execute(meeting_params, form_data, opts \\ []) do
    with {:ok, booking_data} <- prepare_booking_data(meeting_params, form_data),
         {:ok, :validated} <- validate_booking(booking_data, opts),
         {:ok, meeting} <- create_meeting_and_schedule_job_atomically(booking_data) do
      # Post-creation side effects (emails/video)
      handle_post_creation_effects(meeting, opts)

      {:ok, meeting}
    end
  end

  @doc """
  Creates a booking with video room integration.

  Includes optional calendar pre-check for better UX.
  Same options as execute/3 plus video room is automatically enabled.
  """
  @spec execute_with_video_room(meeting_params(), form_data(), keyword()) ::
          {:ok, map()} | {:error, error_reason()}
  def execute_with_video_room(meeting_params, form_data, opts \\ []) do
    opts = Keyword.put(opts, :with_video_room, true)

    with {:ok, booking_data} <- prepare_booking_data(meeting_params, form_data) do
      # Try calendar pre-check for better UX
      case fresh_calendar_check(booking_data) do
        :ok ->
          # Calendar shows available, proceed normally
          execute_internal(booking_data, form_data, opts)

        {:error, :slot_unavailable} ->
          # Fail fast for better UX
          {:error, "This time slot is no longer available. Please select a different time."}

        {:error, _reason} ->
          # Calendar check failed, but continue with atomic booking
          execute_internal(booking_data, form_data, opts)
      end
    end
  end

  # Private functions

  @spec prepare_booking_data(meeting_params(), form_data()) ::
          {:ok, booking_data()} | {:error, String.t()}
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
        organizer_user_id: Map.get(meeting_params, :organizer_user_id)
      }

      {:ok, booking_data}
    else
      {:error, :invalid_date_input} -> {:error, "Invalid date format"}
      {:error, :invalid_format} -> {:error, "Invalid date format"}
      error -> error
    end
  end

  defp normalize_date_input(%Date{} = date), do: {:ok, Date.to_iso8601(date)}
  defp normalize_date_input(date) when is_binary(date), do: {:ok, date}
  defp normalize_date_input(_), do: {:error, :invalid_date_input}

  @spec validate_booking(booking_data(), keyword()) ::
          {:ok, :validated} | {:error, error_reason()}
  defp validate_booking(booking_data, opts) do
    # Get organizer user_id from booking data - now required
    organizer_user_id = Map.get(booking_data, :organizer_user_id)

    case organizer_user_id do
      nil ->
        {:error, :organizer_required}

      user_id ->
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
        require Logger

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
          Task.async(fn ->
            calendar_module().get_events_for_range_fresh(organizer_user_id, date, date)
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
            require Logger

            Logger.warning(
              "Calendar availability check timed out after 5s, proceeding with booking",
              organizer_user_id: organizer_user_id
            )

            {:error, :timeout}
        end
    end
  end

  defp execute_internal(booking_data, _form_data, opts) do
    with {:ok, :validated} <- validate_booking(booking_data, opts),
         {:ok, meeting} <- create_meeting_and_schedule_job_atomically(booking_data) do
      handle_post_creation_effects(meeting, opts)
      {:ok, meeting}
    end
  end

  @spec create_meeting_and_schedule_job_atomically(booking_data()) ::
          {:ok, map()} | {:error, String.t()}
  defp create_meeting_and_schedule_job_atomically(booking_data) do
    meeting_attrs = Policy.build_meeting_attributes(booking_data)

    meeting_attrs
    |> run_meeting_transaction()
    |> map_transaction_result()
  end

  defp run_meeting_transaction(meeting_attrs) do
    Repo.transaction(fn ->
      with {:ok, meeting} <- create_meeting(meeting_attrs),
           {:ok, _} <- schedule_calendar_job(meeting) do
        meeting
      else
        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
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

  defp map_transaction_result({:ok, meeting}), do: {:ok, meeting}

  defp map_transaction_result({:error, :time_conflict}),
    do: {:error, "This time slot is no longer available. Please select a different time."}

  defp map_transaction_result({:error, :validation_error}),
    do: {:error, "Failed to save meeting to database"}

  defp map_transaction_result({:error, _reason}),
    do: {:error, "Failed to save meeting to database"}

  defp handle_post_creation_effects(meeting, opts) do
    # Calendar job was scheduled atomically with meeting creation

    # If explicitly requested, always create video room first and send emails after
    if Keyword.get(opts, :with_video_room, false) do
      schedule_video_room_with_emails(meeting)
    else
      # Auto-detect: if the organizer has a default video provider configured that supports
      # API-based room creation, create the video room before sending emails so the email
      # includes the join link.
      case default_video_provider_for(meeting.organizer_user_id) do
        {:ok, provider} when provider in [:mirotalk, :google_meet, :teams] ->
          schedule_video_room_with_emails(meeting)

        _ ->
          # No supported auto-create provider (none/unknown/custom/etc.)
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
      {:ok, _} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp default_video_provider_for(nil), do: {:error, :organizer_required}

  defp default_video_provider_for(user_id) do
    case VideoIntegrationQueries.get_default_for_user(user_id) do
      {:ok, integration} ->
        # Convert stored provider string (e.g., "google_meet") to atom if known
        raw_provider =
          try do
            String.to_existing_atom(integration.provider)
          rescue
            ArgumentError -> :unknown
          end

        provider = if raw_provider in [:unknown, :none], do: :none, else: raw_provider
        {:ok, provider}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end
end
