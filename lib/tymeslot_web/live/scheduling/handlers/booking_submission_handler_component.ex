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

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.CustomFields
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Security.InputProcessor
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.BookingConfig
  alias TymeslotWeb.Live.Shared.Flash

  require Logger

  @doc """
  Submits a booking using the booking orchestrator.

  This function:
  1. Validates the form data
  2. Checks for duplicate submissions
  3. Calls the booking orchestrator
  4. Handles success/error responses

  Returns:
    * `{:ok, socket}` — booking confirmed, theme should advance to confirmation
    * `{:redirect, socket}` — paid booking awaiting payment, socket already
      carries an external redirect to the Stripe Checkout URL (top-level
      booker only — Stripe blocks framing, so this branch never fires
      from inside an embed iframe)
    * `{:awaiting_payment, socket}` — paid booking inside an embed iframe;
      the socket has been told to open Stripe Checkout in a new tab and
      carries the meeting + checkout URL for the in-iframe wait screen
    * `{:error, socket}` — validation or persistence failure

  ## Examples

      case BookingSubmissionHandlerComponent.submit_booking(socket, booking_params) do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:redirect, redirect_socket} -> {:noreply, redirect_socket}
        {:awaiting_payment, awaiting_socket} -> {:noreply, awaiting_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec submit_booking(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
          | {:redirect, Phoenix.LiveView.Socket.t()}
          | {:awaiting_payment, Phoenix.LiveView.Socket.t()}
          | {:honeypot, Phoenix.LiveView.Socket.t()}
          | {:error, Phoenix.LiveView.Socket.t()}
  def submit_booking(socket, booking_params) do
    Logger.info("Submit event triggered for booking form")

    # Check honeypot first (fastest gate)
    if honeypot_tripped?(booking_params) do
      handle_honeypot_booking(socket, booking_params)
    else
      case InputProcessor.validate_form(booking_params, BookingConfig.booking_field_spec()) do
        {:ok, sanitized_params} ->
          Logger.info("Form validation passed, proceeding to booking")
          validate_and_submit(socket, sanitized_params, booking_params)

        {:error, errors} ->
          Logger.warning("Form validation failed", errors: inspect(errors))

          socket =
            socket
            |> assign(:form, Component.to_form(booking_params))
            |> assign(:validation_errors, errors)
            |> Flash.put_flash(:error, gettext("Please correct the errors below."))

          {:error, socket}
      end
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
    client_ip = ClientIP.get(socket)

    case RateLimiter.check_booking_submission_limit(client_ip) do
      {:allow, _count} ->
        {:ok, socket}

      {:deny, _limit} ->
        Logger.warning("Booking rate limit exceeded", client_ip: inspect(client_ip))

        socket =
          socket
          |> assign(:submitting, false)
          |> Flash.put_flash(:error, "Too many booking attempts. Please try again later.")

        {:error, socket}
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
        Flash.put_flash(
          socket,
          :warning,
          "Your booking is already being processed. Please wait..."
        )

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
        Demo.demo_mode?(socket) and socket.assigns[:is_rescheduling] ->
          "Demo: Meeting rescheduled successfully! (Using the app, you would receive a confirmation email)"

        Demo.demo_mode?(socket) ->
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
      |> assign(:custom_fields_snapshot, Map.get(validated_data, "custom_fields_snapshot", []))
      |> assign(:custom_field_answers, Map.get(validated_data, "custom_field_answers", %{}))
      |> Flash.put_flash(:info, success_message)

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
        "This time slot is no longer available. Please select a different time." ->
          reason

        "Booking time must be in the future" ->
          reason

        _other ->
          if is_binary(reason) and String.length(reason) < 100 do
            reason
          else
            "Failed to create appointment. Please try again."
          end
      end

    socket =
      socket
      |> assign(:submitting, false)
      |> assign(:submission_processed, false)
      |> Flash.put_flash(:error, error_message)

    Logger.error("Failed to create meeting appointment", reason: inspect(reason))

    {:error, socket}
  end

  # Private functions

  defp validate_and_submit(socket, sanitized_params, booking_params) do
    engine = socket.assigns[:engine]
    snapshot = if engine, do: engine.definitions, else: []
    raw_answers = if engine, do: engine.answers, else: %{}

    with {:ok, custom_answers} <- CustomFields.validate_answers(snapshot, raw_answers),
         {:ok, socket} <- check_duplicate_submission(socket),
         {:ok, socket} <- check_rate_limit(socket),
         :ok <- verify_recaptcha(socket, booking_params) do
      enriched_params =
        sanitized_params
        |> Map.put("custom_fields_snapshot", snapshot)
        |> Map.put("custom_field_answers", custom_answers)

      process_booking_submission(socket, enriched_params)
    else
      {:error, field_errors} when is_map(field_errors) and not is_struct(field_errors) ->
        Logger.warning("Custom field validation failed", errors: inspect(field_errors))

        socket =
          socket
          |> assign(:validation_errors, %{custom_fields: field_errors})
          |> Flash.put_flash(:error, gettext("Please correct the errors below."))

        {:error, socket}

      {:error, socket} ->
        {:error, socket}
    end
  end

  defp honeypot_tripped?(params) do
    case Map.get(params, "website") do
      value when is_binary(value) -> value != ""
      _other -> false
    end
  end

  defp handle_honeypot_booking(socket, _booking_params) do
    log_honeypot(socket)

    # Return fake success to mislead the bot
    Logger.info("Honeypot triggered in booking form - simulating success")

    socket =
      socket
      |> assign(:submitting, false)
      |> assign(:custom_fields_snapshot, [])
      |> assign(:custom_field_answers, %{})

    {:honeypot, socket}
  end

  defp log_honeypot(socket) do
    SecurityLogger.log_security_event("booking_honeypot_triggered", %{
      ip_address: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket)
    })
  end

  defp verify_recaptcha(socket, booking_params) do
    recaptcha_token = Map.get(booking_params, "g-recaptcha-response", "")
    client_ip = ClientIP.get(socket)
    user_agent = ClientIP.get_user_agent(socket)

    metadata = %{
      ip: client_ip,
      user_agent: user_agent
    }

    case RecaptchaHelpers.maybe_verify_booking_token(recaptcha_token, metadata) do
      :ok ->
        :ok

      {:error, :recaptcha_failed} ->
        socket =
          socket
          |> assign(:submitting, false)
          |> Flash.put_flash(:error, "Security verification failed. Please try again.")

        {:error, socket}

      {:error, :recaptcha_script_blocked} ->
        socket =
          socket
          |> assign(:submitting, false)
          |> Flash.put_flash(
            :error,
            "Security verification is currently unavailable. This may be caused by JavaScript being disabled, browser privacy extensions (Privacy Badger, uBlock Origin, etc.), or network security policies. Please adjust your settings or contact support if the problem persists."
          )

        {:error, socket}
    end
  end

  defp process_booking_submission(socket, sanitized_params) do
    form = Component.to_form(sanitized_params)
    socket = assign(socket, :form, form)

    # Prepare parameters for orchestrator
    params = %{
      form_data: sanitized_params,
      meeting_params: %{
        date: socket.assigns.selected_date,
        time: socket.assigns.selected_time,
        duration: resolve_duration_minutes(socket),
        user_timezone: socket.assigns.user_timezone,
        organizer_user_id: socket.assigns.organizer_user_id,
        meeting_type_id: get_meeting_type_id(socket),
        attendee_locale:
          socket.assigns[:locale] || Application.get_env(:tymeslot, :locales)[:default] || "en",
        # Always true for public booking flow
        with_video_room: true,
        custom_fields_snapshot: Map.get(sanitized_params, "custom_fields_snapshot", []),
        custom_field_answers: Map.get(sanitized_params, "custom_field_answers", %{})
      }
    }

    opts = [
      is_rescheduling: socket.assigns[:is_rescheduling] || false,
      reschedule_uid: socket.assigns[:reschedule_meeting_uid],
      organizer_user_id: socket.assigns[:organizer_user_id]
    ]

    orchestrator = Demo.get_orchestrator(socket)

    case orchestrator.submit_booking(params, opts) do
      {:ok, :payment_required, %{meeting: meeting, checkout_url: url}} ->
        handle_payment_required(socket, meeting, url, sanitized_params)

      {:ok, meeting} ->
        handle_booking_success(socket, meeting, sanitized_params)

      {:error, errors} when is_list(errors) ->
        error_map = Enum.into(errors, %{})

        socket =
          socket
          |> assign(:form, Component.to_form(sanitized_params))
          |> assign(:validation_errors, error_map)
          |> assign(:submitting, false)
          |> assign(:submission_processed, false)
          |> Flash.put_flash(
            :error,
            gettext("Please correct the errors below before submitting.")
          )

        {:error, socket}

      {:error, reason} ->
        handle_booking_error(socket, reason)
    end
  end

  defp handle_payment_required(socket, meeting, url, sanitized_params) do
    if socket.assigns[:embedded] do
      handle_payment_required_embedded(socket, meeting, url, sanitized_params)
    else
      handle_payment_required_top_level(socket, url)
    end
  end

  defp handle_payment_required_top_level(socket, url) do
    Logger.info("Booking redirecting to Stripe Checkout for payment", checkout_url: url)

    socket =
      socket
      |> assign(:submitting, false)
      |> LiveView.redirect(external: url)

    {:redirect, socket}
  end

  # Stripe Checkout cannot render inside an iframe, so embedded bookers
  # open Checkout in a new tab and stay on a "complete in new tab" screen.
  # The iframe LiveView subscribes to `meeting_payment:<id>` and flips to
  # the confirmation view when the webhook broadcasts `:paid`, or back to
  # the booking form on `:expired`.
  defp handle_payment_required_embedded(socket, meeting, url, sanitized_params) do
    Logger.info("Embedded booking awaiting payment in new tab",
      meeting_id: meeting.id,
      checkout_url: url
    )

    if LiveView.connected?(socket) do
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "meeting_payment:#{meeting.id}")
    end

    # Seed the custom-answer assigns now so the confirmation view can render
    # when the `:paid` webhook flips this socket to `:confirmation` — that
    # transition carries no params, unlike the synchronous success path.
    socket =
      socket
      |> assign(:submitting, false)
      |> assign(:awaiting_payment_meeting, meeting)
      |> assign(:awaiting_payment_checkout_url, url)
      |> assign(:custom_fields_snapshot, Map.get(sanitized_params, "custom_fields_snapshot", []))
      |> assign(:custom_field_answers, Map.get(sanitized_params, "custom_field_answers", %{}))
      |> LiveView.push_event("payment_redirect_open_tab", %{url: url})

    {:awaiting_payment, socket}
  end

  defp resolve_duration_minutes(socket) do
    case socket.assigns[:meeting_type] do
      %{duration_minutes: mins} when is_integer(mins) ->
        mins

      _other ->
        case socket.assigns[:duration] || socket.assigns[:selected_duration] do
          nil -> 30
          val -> TimeSlots.parse_duration(val)
        end
    end
  end

  defp get_meeting_type_id(socket) do
    case socket.assigns[:meeting_type] do
      %{id: id} -> id
      _other -> nil
    end
  end
end
