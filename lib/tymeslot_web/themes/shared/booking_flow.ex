defmodule TymeslotWeb.Themes.Shared.BookingFlow do
  @moduledoc """
  Shared booking orchestration for all scheduling themes.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.Component
  alias Tymeslot.Security.InputProcessor
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingSubmissionHandlerComponent
  alias TymeslotWeb.Live.Scheduling.Helpers

  @booking_field_spec [
    {"name", :name},
    {"email", :email},
    {"message", :message, [required: false, min_length: 0]}
  ]

  require Logger

  @type transition_fun :: (Phoenix.LiveView.Socket.t(), atom(), map() ->
                             Phoenix.LiveView.Socket.t())

  @doc """
  Handles booking submission from the LiveView.
  This centralizes the validation and submission logic by delegating to
  the shared BookingSubmissionHandlerComponent.
  """
  @spec submit_booking(Phoenix.LiveView.Socket.t(), map(), transition_fun()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def submit_booking(socket, booking_params, transition_fun) do
    case BookingSubmissionHandlerComponent.submit_booking(socket, booking_params) do
      {:ok, socket} ->
        # On success, transition to confirmation
        {:noreply, transition_fun.(socket, :confirmation, %{})}

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  @spec handle_form_validation(Phoenix.LiveView.Socket.t(), map()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_form_validation(socket, booking_params) do
    # Track whether the user has interacted with the form to avoid showing
    # validation errors on initial render or prefilled data.
    form_touched =
      socket.assigns[:form_touched] ||
        Map.has_key?(booking_params, "_target")

    case InputProcessor.validate_form(booking_params, @booking_field_spec) do
      {:ok, sanitized_params} ->
        form = Component.to_form(sanitized_params)

        socket =
          socket
          |> assign(:form, form)
          |> assign(:validation_errors, %{})
          |> assign(:form_touched, form_touched)

        {:noreply, socket}

      {:error, errors} ->
        form = Component.to_form(booking_params)

        # Only assign validation errors if the form has been touched.
        # This prevents showing errors immediately when the booking step loads.
        socket =
          if form_touched do
            socket
            |> assign(:form, form)
            |> Helpers.assign_form_errors(errors)
          else
            socket
            |> assign(:form, form)
            |> assign(:validation_errors, %{})
          end

        socket = assign(socket, :form_touched, form_touched)

        {:noreply, socket}
    end
  end
end
