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
          {:redirect, updated_socket} -> {:noreply, updated_socket}
          {:awaiting_payment, updated_socket} -> {:noreply, updated_socket}
          {:honeypot, updated_socket} -> {:noreply, updated_socket}
          {:slot_taken, updated_socket} -> {:noreply, updated_socket}
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
  alias Tymeslot.Bookings.DemoOrchestrator
  alias Tymeslot.CustomFields
  alias Tymeslot.Demo
  alias Tymeslot.Infrastructure.Security.RecaptchaHelpers
  alias Tymeslot.Security.InputProcessor
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.BookingConfig
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
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
    * `{:slot_taken, socket}` — the chosen slot was booked by someone else
      between selection and submit; the caller should return the booker to
      the schedule step with a fresh slot list rather than strand them on
      the form with the now-invalid slot
    * `{:error, socket}` — validation or persistence failure

  ## Examples

      case BookingSubmissionHandlerComponent.submit_booking(socket, booking_params) do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:redirect, redirect_socket} -> {:noreply, redirect_socket}
        {:awaiting_payment, awaiting_socket} -> {:noreply, awaiting_socket}
        {:slot_taken, retry_socket} -> {:noreply, retry_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec submit_booking(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
          | {:redirect, Phoenix.LiveView.Socket.t()}
          | {:awaiting_payment, Phoenix.LiveView.Socket.t()}
          | {:honeypot, Phoenix.LiveView.Socket.t()}
          | {:slot_taken, Phoenix.LiveView.Socket.t()}
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
            |> Flash.put_flash(:error, dgettext("booking", "Please correct the errors below."))

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
          |> release_submission()
          |> Flash.put_flash(
            :error,
            dgettext("booking", "Too many booking attempts. Please try again later.")
          )

        {:error, socket}
    end
  end

  @doc """
  Checks the per-recipient booking rate limit.

  Complements the per-IP limit: stops an attacker rotating source IPs from
  bombing a single attendee mailbox with confirmation emails. Keyed on the
  validated attendee email address.
  """
  @spec check_recipient_rate_limit(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def check_recipient_rate_limit(socket, %{"email" => email})
      when is_binary(email) and email != "" do
    case RateLimiter.check_booking_recipient_limit(email) do
      :ok ->
        {:ok, socket}

      {:error, :rate_limited, _message} ->
        Logger.warning("Booking recipient rate limit exceeded",
          operation: "booking",
          limit_type: "recipient"
        )

        socket =
          socket
          |> release_submission()
          |> Flash.put_flash(
            :error,
            dgettext("booking", "Too many booking attempts. Please try again later.")
          )

        {:error, socket}
    end
  end

  def check_recipient_rate_limit(socket, _params), do: {:ok, socket}

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
          dgettext("booking", "Your booking is already being processed. Please wait...")
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
      |> assign(:guest_emails, socket.assigns[:guest_emails] || [])
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
  @spec handle_booking_error(Phoenix.LiveView.Socket.t(), atom() | String.t()) ::
          {:error, Phoenix.LiveView.Socket.t()}
  def handle_booking_error(socket, reason) do
    socket =
      socket
      |> release_submission()
      |> Flash.put_flash(:error, BookingErrorMessage.message(reason))

    Logger.error("Failed to create meeting appointment", reason: inspect(reason))

    {:error, socket}
  end

  # Private functions

  # Ends an in-flight submission attempt: clears the spinner *and* releases the
  # duplicate-submission lock claimed by `check_duplicate_submission/1`.
  #
  # Both flags must move together. The lock is claimed before the rate-limit and
  # reCAPTCHA gates run, so a failure branch that clears only `:submitting`
  # leaves `:submission_processed` set and wedges the form: every retry in that
  # session is rejected as "already being processed" until the booker reloads
  # the page. Route every non-success exit through here rather than assigning
  # the flags by hand.
  defp release_submission(socket) do
    socket
    |> assign(:submitting, false)
    |> assign(:submission_processed, false)
  end

  defp validate_and_submit(socket, sanitized_params, booking_params) do
    engine = socket.assigns[:engine]
    snapshot = if engine, do: engine.definitions, else: []
    raw_answers = if engine, do: engine.answers, else: %{}

    with {:ok, custom_answers} <- CustomFields.validate_answers(snapshot, raw_answers),
         {:ok, socket} <- check_duplicate_submission(socket),
         {:ok, socket} <- check_rate_limit(socket),
         :ok <- verify_recaptcha(socket, booking_params),
         {:ok, socket} <- check_recipient_rate_limit(socket, sanitized_params) do
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
          |> Flash.put_flash(:error, dgettext("booking", "Please correct the errors below."))

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
          |> release_submission()
          |> Flash.put_flash(
            :error,
            dgettext("booking", "Security verification failed. Please try again.")
          )

        {:error, socket}

      {:error, :recaptcha_script_blocked} ->
        socket =
          socket
          |> release_submission()
          |> Flash.put_flash(
            :error,
            dgettext(
              "booking",
              "Security verification is currently unavailable. This may be caused by JavaScript being disabled, browser privacy extensions (Privacy Badger, uBlock Origin, etc.), or network security policies. Please adjust your settings or contact support if the problem persists."
            )
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
      meeting_params:
        Map.merge(
          build_meeting_params(socket, sanitized_params),
          socket.assigns[:tracking] || %{}
        )
    }

    opts = [
      is_rescheduling: socket.assigns[:is_rescheduling] || false,
      reschedule_uid: socket.assigns[:reschedule_meeting_uid],
      organizer_user_id: socket.assigns[:organizer_user_id]
    ]

    case booking_orchestrator(socket) do
      :preview_without_valid_token ->
        handle_expired_preview(socket)

      orchestrator ->
        handle_submit_result(socket, orchestrator.submit_booking(params, opts), sanitized_params)
    end
  end

  defp handle_submit_result(socket, result, sanitized_params) do
    case result do
      {:ok, :payment_required, %{meeting: meeting, checkout_url: url}} ->
        handle_payment_required(socket, meeting, url, sanitized_params)

      {:ok, meeting} ->
        handle_booking_success(socket, meeting, sanitized_params)

      {:error, errors} when is_list(errors) ->
        handle_field_errors(socket, errors, sanitized_params)

      {:error, :slot_taken} ->
        handle_slot_taken(socket)

      {:error, reason} ->
        handle_booking_error(socket, reason)
    end
  end

  defp handle_expired_preview(socket) do
    socket =
      socket
      |> release_submission()
      |> Flash.put_flash(
        :error,
        dgettext("booking", "Preview session expired. Reload the page to continue.")
      )

    {:error, socket}
  end

  defp handle_field_errors(socket, errors, sanitized_params) do
    socket =
      socket
      |> assign(:form, Component.to_form(sanitized_params))
      |> assign(:validation_errors, Enum.into(errors, %{}))
      |> release_submission()
      |> Flash.put_flash(
        :error,
        dgettext("booking", "Please correct the errors below before submitting.")
      )

    {:error, socket}
  end

  # The slot was booked out from under this attendee between selecting it and
  # submitting (server-side `FOR UPDATE NOWAIT` correctly refused the double
  # booking). The domain layer signals this with the semantic `:slot_taken`
  # atom (see `Tymeslot.Bookings.Orchestrator.submit_booking/2`) rather than a
  # display string, so this routing decision never depends on copy text. Stop
  # the in-flight submission and hand back a `:slot_taken` tuple so the flow
  # returns the booker to the schedule step with refreshed availability —
  # never leave them stranded on the form re-submitting a dead slot.
  defp handle_slot_taken(socket) do
    socket =
      socket
      |> release_submission()
      |> Flash.put_flash(:error, BookingErrorMessage.message(:slot_taken))

    {:slot_taken, socket}
  end

  # Selects the booking orchestrator based on the current preview state.
  #
  # Three cases:
  #
  #   1. `:owner_preview` true — the token was verified and bound to this page's
  #      owner. Simulate via DemoOrchestrator: no DB row, email, or calendar
  #      event.
  #
  #   2. `:theme_preview` true but `:owner_preview` false — the preview display
  #      flag is active (so the owner believes they are in a simulation), but no
  #      valid owner-bound token was present or it expired during the session.
  #      Persisting a real booking here would be invisible to the owner. Fail
  #      closed: return `:preview_without_valid_token` so the caller blocks the
  #      submission with an explicit error.
  #
  #   3. Neither flag set — a normal public booking; dispatch to the real
  #      (or SaaS-demo-mode) orchestrator.
  defp booking_orchestrator(socket) do
    cond do
      socket.assigns[:owner_preview] -> DemoOrchestrator
      socket.assigns[:theme_preview] -> :preview_without_valid_token
      true -> Demo.get_orchestrator(socket)
    end
  end

  defp build_meeting_params(socket, sanitized_params) do
    %{
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
      custom_field_answers: Map.get(sanitized_params, "custom_field_answers", %{}),
      guest_emails: socket.assigns[:guest_emails] || []
    }
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
      |> assign(:guest_emails, socket.assigns[:guest_emails] || [])
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
