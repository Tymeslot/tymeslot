defmodule TymeslotWeb.Themes.Shared.StateMachineHelpers do
  @moduledoc """
  Shared state machine logic for scheduling flows.
  """

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Lengths

  # `awaiting_payment` is a transitional state used by embedded paid
  # bookings: Stripe Checkout opens in a new tab and the iframe waits for
  # the webhook to broadcast `:paid` (→ `:confirmation`) or `:expired`
  # (→ `:booking`). It shares step 4 with `:confirmation` so step
  # navigation does not let the attendee jump back during payment.
  @states_with_questions %{
    overview: %{step: 1, next: :schedule, prev: nil},
    schedule: %{step: 2, next: :questions, prev: :overview},
    questions: %{step: 3, next: :booking, prev: :schedule},
    booking: %{step: 4, next: :confirmation, prev: :questions},
    # `awaiting_payment` shares the final step with `:confirmation` (here step
    # 5) for the same reason it does in the default map: step navigation must
    # not let the attendee jump back while a paid booking is mid-payment.
    awaiting_payment: %{step: 5, prev: :booking},
    confirmation: %{step: 5, prev: :booking}
  }

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
  Returns the state map appropriate for a meeting type — 5 states when
  the meeting type has at least one custom field, the default 4 otherwise.
  """
  @spec states_for(map()) :: map()
  def states_for(%{custom_fields: defs}) when is_list(defs) and defs != [],
    do: @states_with_questions

  def states_for(_meeting_type), do: @default_states

  @doc """
  The state map for the flow the socket is in: `states_for/1`, plus the
  `:length` step when the booker has a length to choose.

  The duration step belongs to the first step (in Quill's step indicator it
  is part of "Duration"), so it shares step 1 with `:overview`. A reschedule
  keeps the length that was booked and never shows it.
  """
  @spec states_for_socket(Phoenix.LiveView.Socket.t()) :: map()
  def states_for_socket(socket) do
    meeting_type = socket.assigns[:meeting_type] || %{}
    states = states_for(meeting_type)

    if choose_length?(socket), do: with_length_step(states), else: states
  end

  @doc "Whether the booker picks a length in a step of its own."
  @spec choose_length?(Phoenix.LiveView.Socket.t() | map()) :: boolean()
  def choose_length?(%Phoenix.LiveView.Socket{assigns: assigns}), do: choose_length?(assigns)

  def choose_length?(assigns) when is_map(assigns) do
    Lengths.multiple?(assigns[:meeting_type]) and assigns[:reschedule_meeting_uid] == nil
  end

  @doc """
  Whether the flow still has to ask for a length before scheduling: the type
  offers several and none of them has been chosen.
  """
  @spec needs_length_choice?(Phoenix.LiveView.Socket.t()) :: boolean()
  def needs_length_choice?(socket) do
    is_nil(socket.redirected) and choose_length?(socket) and
      not Lengths.offers?(
        socket.assigns[:meeting_type],
        socket.assigns[:chosen_length_minutes]
      )
  end

  defp with_length_step(states) do
    states
    |> put_in([:overview, :next], :length)
    |> put_in([:schedule, :prev], :length)
    |> Map.put(:length, %{step: 1, next: :schedule, prev: :overview})
  end

  @doc """
  The state a step number in the indicator leads to. `:length` shares step
  1 with `:overview` and is never the target: step 1 goes back to the start.
  """
  @spec state_for_step(map(), integer() | nil) :: atom() | nil
  def state_for_step(states, step) do
    case Enum.find(states, fn {state, %{step: n}} -> n == step and state != :length end) do
      {state, _meta} -> state
      nil -> nil
    end
  end

  @doc """
  Checks if navigation to a target state is allowed based on the current state's step.
  Only allows navigation to previous or current steps.
  """
  @spec can_navigate_to_step?(Phoenix.LiveView.Socket.t(), atom(), map()) :: boolean()
  def can_navigate_to_step?(socket, target_state, states) do
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
          :ok | {:error, MeetingTypes.Duration.selection_error() | Calculate.selection_error()}
  def validate_state_transition(socket, current_state, next_state) do
    case {current_state, next_state} do
      {:overview, :schedule} ->
        validate_step_requirements(socket, :schedule)

      {:overview, :length} ->
        validate_step_requirements(socket, :schedule)

      {:length, :schedule} ->
        validate_chosen_length(socket)

      {:schedule, :questions} ->
        validate_step_requirements(socket, :questions)

      {:questions, :booking} ->
        :ok

      {:schedule, :booking} ->
        validate_step_requirements(socket, :booking)

      _other ->
        :ok
    end
  end

  @spec validate_step_requirements(Phoenix.LiveView.Socket.t(), atom()) ::
          :ok | {:error, MeetingTypes.Duration.selection_error() | Calculate.selection_error()}
  defp validate_step_requirements(socket, :schedule) do
    MeetingTypes.validate_duration_selection(
      socket.assigns[:selected_duration],
      validatable_meeting_types(socket)
    )
  end

  # Same precondition as :booking — booker must have selected a date and time.
  defp validate_step_requirements(socket, :questions),
    do: validate_step_requirements(socket, :booking)

  defp validate_step_requirements(socket, :booking) do
    Calculate.validate_time_selection(
      socket.assigns[:selected_date],
      socket.assigns[:selected_time],
      socket.assigns[:available_slots]
    )
  end

  # The booker's selection is authoritative once resolved. A private type is
  # reached by its direct link and is absent from the public `:meeting_types`
  # list, so include the resolved `:meeting_type` to validate against.
  defp validatable_meeting_types(socket) do
    list = socket.assigns[:meeting_types] || []

    case socket.assigns[:meeting_type] do
      nil -> list
      meeting_type -> [meeting_type | list]
    end
  end

  defp validate_chosen_length(socket) do
    case socket.assigns[:chosen_length_minutes] do
      nil ->
        {:error, :duration_required}

      minutes ->
        if Lengths.offers?(socket.assigns[:meeting_type], minutes),
          do: :ok,
          else: {:error, :duration_invalid}
    end
  end
end
