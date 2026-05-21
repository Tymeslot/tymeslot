defmodule TymeslotWeb.Themes.Shared.BookingFlow do
  @moduledoc """
  Shared booking orchestration for all scheduling themes.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Phoenix.Component
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.Live.Scheduling.BookingConfig
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingSubmissionHandlerComponent

  require Logger

  @type transition_fun :: (Phoenix.LiveView.Socket.t(), atom(), map() ->
                             Phoenix.LiveView.Socket.t())

  @doc """
  Handles booking submission from the LiveView.
  This centralizes the validation and submission logic by delegating to
  the shared BookingSubmissionHandlerComponent.

  When the meeting type requires payment, the handler returns a socket that
  is already configured to redirect to the Stripe Checkout URL — we forward
  that socket without transitioning to the confirmation step so the
  attendee leaves the booking flow for the hosted payment page.

  When the booker is embedded inside an iframe (Stripe Checkout cannot
  render in an iframe), the handler instead instructs the browser to open
  Checkout in a new tab and we transition to the local `:awaiting_payment`
  view; the LiveView subscribes to `meeting_payment:<id>` and flips back
  to `:confirmation` on `:paid` or `:booking` on `:expired`.
  """
  @spec submit_booking(Phoenix.LiveView.Socket.t(), map(), transition_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def submit_booking(socket, booking_params, transition_fun) do
    if socket.assigns[:submitting] do
      {:noreply, socket}
    else
      socket = assign(socket, :submitting, true)

      case BookingSubmissionHandlerComponent.submit_booking(socket, booking_params) do
        {:ok, socket} ->
          {:noreply, transition_fun.(socket, :confirmation, %{})}

        {:redirect, socket} ->
          {:noreply, socket}

        {:awaiting_payment, socket} ->
          {:noreply, transition_fun.(socket, :awaiting_payment, %{})}

        {:honeypot, socket} ->
          {:noreply,
           put_flash(
             socket,
             :info,
             "Booking submitted successfully! You'll receive a confirmation email shortly."
           )}

        {:error, socket} ->
          {:noreply, assign(socket, :submitting, false)}
      end
    end
  end

  @spec handle_form_validation(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_form_validation(socket, booking_params) do
    # Show validation errors only after the user has interacted with the form.
    # `touched_fields` is populated by the field_blur event handler; `_target`
    # is a fallback for phx-change events that include it in the params.
    touched_fields = socket.assigns[:touched_fields] || MapSet.new()

    form_touched =
      socket.assigns[:form_touched] ||
        MapSet.size(touched_fields) > 0 ||
        Map.has_key?(booking_params, "_target")

    # Filter errors to only show for fields the user has actually interacted
    # with (blurred). This matches the per-field validation UX of auth and
    # contact forms — touching name doesn't reveal email errors.
    visible_errors =
      case InputProcessor.validate_form(booking_params, BookingConfig.booking_field_spec()) do
        {:ok, _sanitized_params} -> %{}
        {:error, errors} -> filter_errors_for_touched_fields(errors, touched_fields)
      end

    socket =
      socket
      |> assign(:form, Component.to_form(booking_params))
      |> assign(:validation_errors, visible_errors)
      |> assign(:form_touched, form_touched)

    {:noreply, socket}
  end

  defp filter_errors_for_touched_fields(errors, touched_fields) do
    Map.filter(errors, fn {field, _msg} ->
      MapSet.member?(touched_fields, Atom.to_string(field))
    end)
  end
end
