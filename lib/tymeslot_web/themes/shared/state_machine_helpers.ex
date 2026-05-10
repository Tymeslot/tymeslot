defmodule TymeslotWeb.Themes.Shared.StateMachineHelpers do
  @moduledoc """
  Shared state machine logic for scheduling flows.
  """

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.MeetingTypes

  # `awaiting_payment` is a transitional state used by embedded paid
  # bookings: Stripe Checkout opens in a new tab and the iframe waits for
  # the webhook to broadcast `:paid` (→ `:confirmation`) or `:expired`
  # (→ `:booking`). It shares step 4 with `:confirmation` so step
  # navigation does not let the attendee jump back during payment.
  @default_states %{
    overview: %{step: 1, next: :schedule, prev: nil},
    schedule: %{step: 2, next: :booking, prev: :overview},
    booking: %{step: 3, next: :confirmation, prev: :schedule},
    awaiting_payment: %{step: 4, prev: :booking},
    confirmation: %{step: 4, prev: :booking}
  }

  @doc """
  Returns the default 4-step state configuration.
  """
  @spec default_states() :: map()
  def default_states, do: @default_states

  @doc """
  Checks if navigation to a target state is allowed based on the current state's step.
  Only allows navigation to previous or current steps.
  """
  @spec can_navigate_to_step?(Phoenix.LiveView.Socket.t(), atom(), map()) :: boolean()
  def can_navigate_to_step?(socket, target_state, states \\ @default_states) do
    current_state = socket.assigns[:current_state]

    with %{step: current_step} <- states[current_state],
         %{step: target_step} <- states[target_state] do
      target_step <= current_step
    else
      _other -> false
    end
  end

  @spec determine_initial_state(atom()) :: :overview | :schedule | :booking | :confirmation
  def determine_initial_state(live_action) do
    case live_action do
      :overview -> :overview
      :schedule -> :schedule
      :booking -> :booking
      :confirmation -> :confirmation
      _other -> :overview
    end
  end

  @spec validate_state_transition(Phoenix.LiveView.Socket.t(), atom(), atom()) ::
          :ok | {:error, String.t()}
  def validate_state_transition(socket, current_state, next_state) do
    case {current_state, next_state} do
      {:overview, :schedule} ->
        validate_step_requirements(socket, :schedule)

      {:schedule, :booking} ->
        validate_step_requirements(socket, :booking)

      _other ->
        :ok
    end
  end

  @spec validate_step_requirements(Phoenix.LiveView.Socket.t(), atom()) ::
          :ok | {:error, String.t()}
  def validate_step_requirements(socket, :schedule) do
    MeetingTypes.validate_duration_selection(
      socket.assigns[:selected_duration],
      socket.assigns[:meeting_types]
    )
  end

  def validate_step_requirements(socket, :booking) do
    Calculate.validate_time_selection(
      socket.assigns[:selected_date],
      socket.assigns[:selected_time],
      socket.assigns[:available_slots]
    )
  end
end
