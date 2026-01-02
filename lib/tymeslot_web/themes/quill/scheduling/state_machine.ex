defmodule TymeslotWeb.Themes.Quill.Scheduling.StateMachine do
  @moduledoc """
  State machine helpers for the Quill scheduling flow.
  Extracted from the LiveView to reduce module size and improve testability.
  """

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.MeetingTypes

  @states %{
    overview: %{step: 1, next: :schedule, prev: nil},
    schedule: %{step: 2, next: :booking, prev: :overview},
    booking: %{step: 3, next: :confirmation, prev: :schedule},
    confirmation: %{step: 4, prev: nil}
  }

  @spec determine_initial_state(atom()) :: :overview | :schedule | :booking | :confirmation
  def determine_initial_state(live_action) do
    case live_action do
      :overview -> :overview
      :schedule -> :schedule
      :booking -> :booking
      :confirmation -> :confirmation
      _ -> :overview
    end
  end

  @spec can_navigate_to_step?(Phoenix.LiveView.Socket.t(), atom()) :: boolean()
  def can_navigate_to_step?(socket, target_state) do
    current_step = @states[socket.assigns.current_state][:step]
    target_step = @states[target_state][:step]
    target_step <= current_step
  end

  @spec validate_state_transition(Phoenix.LiveView.Socket.t(), atom(), atom()) ::
          :ok | {:error, String.t()}
  def validate_state_transition(socket, current_state, next_state) do
    case {current_state, next_state} do
      {:overview, :schedule} ->
        validate_step_requirements(socket, :schedule)

      {:schedule, :booking} ->
        validate_step_requirements(socket, :booking)

      _ ->
        :ok
    end
  end

  @spec validate_step_requirements(Phoenix.LiveView.Socket.t(), atom()) ::
          :ok | {:error, String.t()}
  def validate_step_requirements(socket, :schedule) do
    MeetingTypes.validate_duration_selection(
      socket.assigns.selected_duration,
      socket.assigns.meeting_types
    )
  end

  def validate_step_requirements(socket, :booking) do
    Calculate.validate_time_selection(
      socket.assigns.selected_date,
      socket.assigns.selected_time,
      socket.assigns.available_slots
    )
  end
end
