defmodule TymeslotWeb.Themes.Quill.Scheduling.BookingFlow do
  @moduledoc """
  Booking orchestration extracted from the Quill LiveView.
  Returns {:noreply, socket} tuples for LiveView handlers.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.Component
  alias Tymeslot.Bookings.Orchestrator
  alias Tymeslot.Security.FormValidation
  alias Tymeslot.TemplateDemo.Context
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingSubmissionHandlerComponent
  alias TymeslotWeb.Live.Scheduling.Helpers

  require Logger

  @type transition_fun :: (Phoenix.LiveView.Socket.t(), atom(), map() ->
                             Phoenix.LiveView.Socket.t())

  @spec handle_form_validation(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_form_validation(socket, booking_params) do
    case FormValidation.validate_booking_form(booking_params) do
      {:ok, sanitized_params} ->
        form = Component.to_form(sanitized_params)

        socket =
          socket
          |> assign(:form, form)
          |> assign(:validation_errors, [])

        {:noreply, socket}

      {:error, errors} ->
        {:ok, sanitized_params} =
          FormValidation.sanitize_booking_params(booking_params)

        form = Component.to_form(sanitized_params)

        socket =
          socket
          |> assign(:form, form)
          |> Helpers.assign_form_errors(errors)

        {:noreply, socket}
    end
  end

  @spec process_booking_submission(Phoenix.LiveView.Socket.t(), transition_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def process_booking_submission(socket, transition_fun) do
    Logger.info("Submit event triggered for booking form")

    case FormValidation.validate_booking_form(socket.assigns.form.params || %{}) do
      {:ok, _sanitized_params} ->
        Logger.info("Form validation passed, proceeding to booking")
        socket = assign(socket, :validation_errors, [])
        execute_booking_flow(socket, transition_fun)

      {:error, errors} ->
        Logger.warning("Form validation failed: #{inspect(errors)}")

        {:ok, sanitized_params} =
          FormValidation.sanitize_booking_params(socket.assigns.form.params || %{})

        form = Component.to_form(sanitized_params)

        socket =
          socket
          |> assign(:form, form)
          |> assign(:validation_errors, errors)
          |> put_flash(:error, "Please correct the errors below.")

        {:noreply, socket}
    end
  end

  defp execute_booking_flow(socket, transition_fun) do
    case check_duplicate_submission(socket) do
      {:duplicate, socket} -> {:noreply, socket}
      {:proceed, socket} -> do_execute_booking_flow(socket, transition_fun)
    end
  end

  defp do_execute_booking_flow(socket, transition_fun) do
    params = build_booking_params(socket)
    opts = build_booking_opts(socket)

    if Context.demo_mode?(socket) do
      handle_demo_booking(socket, transition_fun)
    else
      handle_regular_booking(socket, params, opts, transition_fun)
    end
  end

  defp build_booking_params(socket) do
    %{
      form_data: socket.assigns.form.source,
      meeting_params: %{
        date: socket.assigns.selected_date,
        time: socket.assigns.selected_time,
        duration: socket.assigns.duration || socket.assigns.selected_duration,
        user_timezone: socket.assigns.user_timezone,
        organizer_user_id: socket.assigns.organizer_user_id,
        with_video_room: true
      }
    }
  end

  defp build_booking_opts(socket) do
    [
      is_rescheduling: socket.assigns.is_rescheduling,
      reschedule_uid: socket.assigns.reschedule_meeting_uid,
      client_ip: socket.assigns.client_ip || ClientIP.get(socket)
    ]
  end

  defp handle_demo_booking(socket, transition_fun) do
    Logger.info("Demo mode: Skipping actual booking creation, showing confirmation")

    demo_meeting_uid = "demo-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    socket =
      socket
      |> set_confirmation_data(demo_meeting_uid)
      |> put_flash(
        :info,
        "Demo: Booking confirmed! (Using the app, you would receive a confirmation email)"
      )

    {:noreply, transition_fun.(socket, :confirmation, %{})}
  end

  defp handle_regular_booking(socket, params, opts, transition_fun) do
    case Orchestrator.submit_booking(params, opts) do
      {:ok, meeting} ->
        handle_booking_success(socket, meeting, transition_fun)

      {:error, errors} when is_list(errors) ->
        handle_validation_errors(socket, errors)

      {:error, reason} ->
        handle_booking_error(socket, reason)
    end
  end

  defp handle_booking_success(socket, meeting, transition_fun) do
    {:ok, socket} =
      BookingSubmissionHandlerComponent.handle_booking_success(
        socket,
        meeting,
        socket.assigns.form.source
      )

    socket = set_confirmation_data(socket, meeting.uid)
    {:noreply, transition_fun.(socket, :confirmation, %{})}
  end

  defp handle_validation_errors(socket, errors) do
    socket =
      socket
      |> assign(:validation_errors, errors)
      |> assign(:submitting, false)
      |> assign(:submission_processed, false)
      |> put_flash(:error, "Please correct the errors below before submitting.")

    {:noreply, socket}
  end

  defp set_confirmation_data(socket, meeting_uid) do
    socket
    |> assign(:name, socket.assigns.form.source["name"] || "Guest")
    |> assign(:email, socket.assigns.form.source["email"] || "")
    |> assign(:meeting_uid, meeting_uid)
  end

  defp handle_booking_error(socket, reason) do
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

    {:noreply, socket}
  end

  defp check_duplicate_submission(socket) do
    if socket.assigns.submission_processed do
      Logger.warning("Duplicate submission attempt detected")

      socket =
        put_flash(socket, :warning, "Your booking is already being processed. Please wait...")

      {:duplicate, socket}
    else
      socket =
        socket
        |> assign(:submission_processed, true)
        |> assign(:submitting, true)

      {:proceed, socket}
    end
  end
end
