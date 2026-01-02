defmodule TymeslotWeb.Live.Scheduling.Handlers.BookingSubmissionHandlerComponent do
  @moduledoc """
  Specialized handler for booking submission operations in scheduling themes.

  This handler provides common booking submission functionality that can be used across
  different themes, eliminating code duplication while maintaining theme independence.

  ## Usage

      alias TymeslotWeb.Live.Scheduling.Handlers.BookingSubmissionHandlerComponent

      # In your theme's handle_info callback:
      def handle_info({:step_event, :booking, :submit, data}, socket) do
        case BookingSubmissionHandlerComponent.submit_booking(socket, data) do
          {:ok, updated_socket} -> {:noreply, updated_socket}
          {:error, error_socket} -> {:noreply, error_socket}
        end
      end

  ## Available Functions

  - `submit_booking/2` - Process booking submission with orchestrator
  - `handle_booking_success/3` - Handle successful booking creation
  - `handle_booking_error/2` - Handle booking submission errors
  - `check_duplicate_submission/1` - Check for duplicate submissions
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.Component
  alias Tymeslot.Security.FormValidation
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TemplateDemo.Context

  require Logger

  @doc """
  Submits a booking using the booking orchestrator.

  This function:
  1. Validates the form data
  2. Checks for duplicate submissions
  3. Calls the booking orchestrator
  4. Handles success/error responses

  ## Examples

      case BookingSubmissionHandlerComponent.submit_booking(socket, booking_params) do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec submit_booking(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def submit_booking(socket, booking_params) do
    Logger.info("Submit event triggered for booking form")

    case FormValidation.validate_booking_form(booking_params) do
      {:ok, sanitized_params} ->
        Logger.info("Form validation passed, proceeding to booking")

        with {:ok, socket} <- check_duplicate_submission(socket),
             {:ok, socket} <- check_rate_limit(socket) do
          process_booking_submission(socket, sanitized_params)
        else
          {:error, socket} -> {:error, socket}
        end

      {:error, errors} ->
        Logger.warning("Form validation failed: #{inspect(errors)}")
        {:ok, sanitized_params} = FormValidation.sanitize_booking_params(booking_params)
        form = Component.to_form(sanitized_params)

        socket =
          socket
          |> assign(:form, form)
          |> assign(:validation_errors, errors)
          |> put_flash(:error, "Please correct the errors below.")

        {:error, socket}
    end
  end

  @doc """
  Checks rate limit for booking submissions.

  This prevents abuse by limiting the number of booking attempts
  from the same IP address within a time window.
  """
  @spec check_rate_limit(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def check_rate_limit(socket) do
    client_ip = socket.assigns[:client_ip]

    if client_ip do
      case RateLimiter.check_booking_submission_limit(client_ip) do
        {:allow, _count} ->
          {:ok, socket}

        {:deny, _limit} ->
          Logger.warning("Booking rate limit exceeded for IP: #{inspect(client_ip)}")

          socket =
            socket
            |> assign(:submitting, false)
            |> put_flash(:error, "Too many booking attempts. Please try again later.")

          {:error, socket}
      end
    else
      # No client IP available, allow the request
      {:ok, socket}
    end
  end

  @doc """
  Checks for duplicate submission attempts.

  This function prevents duplicate submissions by checking if a submission
  is already being processed.

  ## Examples

      case BookingSubmissionHandlerComponent.check_duplicate_submission(socket) do
        {:ok, socket} -> # Proceed with submission
        {:error, socket} -> # Duplicate submission detected
      end
  """
  @spec check_duplicate_submission(Phoenix.LiveView.Socket.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def check_duplicate_submission(socket) do
    if socket.assigns[:submission_processed] do
      Logger.warning("Duplicate submission attempt detected")

      socket =
        put_flash(socket, :warning, "Your booking is already being processed. Please wait...")

      {:error, socket}
    else
      socket =
        socket
        |> assign(:submission_processed, true)
        |> assign(:submitting, true)

      {:ok, socket}
    end
  end

  @doc """
  Handles successful booking creation.

  This function processes a successful booking response and updates the socket
  with the appropriate success state.

  ## Examples

      {:ok, socket} = BookingSubmissionHandlerComponent.handle_booking_success(
        socket,
        meeting,
        validated_data
      )
  """
  @spec handle_booking_success(Phoenix.LiveView.Socket.t(), map(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def handle_booking_success(socket, meeting, validated_data) do
    success_message =
      cond do
        Context.demo_mode?(socket) and socket.assigns[:is_rescheduling] ->
          "Demo: Meeting rescheduled successfully! (Using the app, you would receive a confirmation email)"

        Context.demo_mode?(socket) ->
          "Demo: Booking submitted successfully! (Using the app, you would receive a confirmation email)"

        socket.assigns[:is_rescheduling] ->
          "Meeting rescheduled successfully!"

        true ->
          "Booking submitted successfully!"
      end

    socket =
      socket
      |> assign(:submitting, false)
      |> assign(:meeting_uid, meeting.uid)
      |> assign(:name, validated_data["name"])
      |> assign(:email, validated_data["email"])
      |> put_flash(:info, success_message)

    {:ok, socket}
  end

  @doc """
  Handles booking submission errors.

  This function processes booking errors and updates the socket with
  appropriate error messages and states.

  ## Examples

      {:error, socket} = BookingSubmissionHandlerComponent.handle_booking_error(
        socket,
        "Time slot unavailable"
      )
  """
  @spec handle_booking_error(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:error, Phoenix.LiveView.Socket.t()}
  def handle_booking_error(socket, reason) do
    error_message =
      case reason do
        "This time slot is no longer available. Please select a different time." -> reason
        _ -> "Failed to create appointment. Please try again."
      end

    socket =
      socket
      |> assign(:submitting, false)
      |> assign(:submission_processed, false)
      |> put_flash(:error, error_message)

    Logger.error("Failed to create meeting appointment", reason: inspect(reason))

    {:error, socket}
  end

  # Private functions

  defp process_booking_submission(socket, sanitized_params) do
    form = Component.to_form(sanitized_params)
    socket = assign(socket, :form, form)

    # Prepare parameters for orchestrator
    params = %{
      form_data: sanitized_params,
      meeting_params: %{
        date: socket.assigns.selected_date,
        time: socket.assigns.selected_time,
        duration: socket.assigns.duration || socket.assigns.selected_duration,
        user_timezone: socket.assigns.user_timezone,
        organizer_user_id: socket.assigns.organizer_user_id,
        # Always true for public booking flow
        with_video_room: true
      }
    }

    opts = [
      is_rescheduling: socket.assigns[:is_rescheduling] || false,
      reschedule_uid: socket.assigns[:reschedule_meeting_uid]
    ]

    # Use demo orchestrator if in demo mode
    orchestrator = Context.get_orchestrator(socket)

    case orchestrator.submit_booking(params, opts) do
      {:ok, meeting} ->
        handle_booking_success(socket, meeting, sanitized_params)

      {:error, errors} when is_list(errors) ->
        socket =
          socket
          |> assign(:validation_errors, errors)
          |> assign(:submitting, false)
          |> assign(:submission_processed, false)
          |> put_flash(:error, "Please correct the errors below before submitting.")

        {:error, socket}

      {:error, reason} ->
        handle_booking_error(socket, reason)
    end
  end
end
