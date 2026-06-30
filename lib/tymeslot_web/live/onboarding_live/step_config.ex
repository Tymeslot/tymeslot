defmodule TymeslotWeb.OnboardingLive.StepConfig do
  @moduledoc """
  Configuration module for onboarding steps and related data.

  Centralises step definitions, validation rules, and configuration
  options for the onboarding flow:
  welcome → profile → connect_calendar → [choose_theme] → buffer_time → booking_window → minimum_notice → ready.

  The `choose_theme` step is *conditional*: it only appears once the user has
  connected a calendar (so their real booking page is publicly ready and can
  be previewed). If they skip the calendar step, the theme step is skipped
  entirely. Because of this, the step sequence is a runtime list rather than a
  fixed constant — numbering and next/previous are derived from that list.
  """

  @typedoc "Represents an onboarding step in the flow."
  @type step ::
          :welcome
          | :profile
          | :connect_calendar
          | :choose_theme
          | :buffer_time
          | :booking_window
          | :minimum_notice
          | :ready

  @typedoc "A label/value tuple used for select options."
  @type option :: {String.t(), non_neg_integer()}

  alias Tymeslot.Validation.Constraints

  @steps_without_theme [
    :welcome,
    :profile,
    :connect_calendar,
    :buffer_time,
    :booking_window,
    :minimum_notice,
    :ready
  ]

  @steps_with_theme [
    :welcome,
    :profile,
    :connect_calendar,
    :choose_theme,
    :buffer_time,
    :booking_window,
    :minimum_notice,
    :ready
  ]

  # Superset of every step that can appear — used only for membership checks.
  @all_steps @steps_with_theme

  @buffer_time_options [
    {"No buffer", 0},
    {"15 min", 15},
    {"30 min", 30},
    {"45 min", 45},
    {"60 min", 60}
  ]

  @buffer_time_values Enum.map(@buffer_time_options, &elem(&1, 1))

  @buffer_minutes_constraints %{
    min: Constraints.buffer_minutes_range().first,
    max: Constraints.buffer_minutes_range().last,
    step: 5,
    default_custom: 20,
    unit: "min",
    color: "turquoise"
  }

  @advance_booking_options [
    {"1 week", 7},
    {"2 weeks", 14},
    {"1 month", 30},
    {"3 months", 90},
    {"6 months", 180},
    {"1 year", 365}
  ]

  @advance_booking_values Enum.map(@advance_booking_options, &elem(&1, 1))

  @advance_booking_constraints %{
    min: Constraints.advance_booking_days_range().first,
    max: Constraints.advance_booking_days_range().last,
    step: 1,
    default_custom: 120,
    unit: "days",
    color: "cyan"
  }

  @min_advance_options [
    {"No minimum", 0},
    {"1 hour", 1},
    {"3 hours", 3},
    {"6 hours", 6},
    {"12 hours", 12},
    {"24 hours", 24},
    {"48 hours", 48}
  ]

  @min_advance_values Enum.map(@min_advance_options, &elem(&1, 1))

  @min_advance_constraints %{
    min: Constraints.min_advance_hours_range().first,
    max: Constraints.min_advance_hours_range().last,
    step: 1,
    default_custom: 8,
    unit: "hours",
    color: "blue"
  }

  @custom_input_config %{
    "buffer_minutes" => %{
      field: :buffer_minutes,
      presets: @buffer_time_values,
      constraints: @buffer_minutes_constraints
    },
    "advance_booking_days" => %{
      field: :advance_booking_days,
      presets: @advance_booking_values,
      constraints: @advance_booking_constraints
    },
    "min_advance_hours" => %{
      field: :min_advance_hours,
      presets: @min_advance_values,
      constraints: @min_advance_constraints
    }
  }

  # -------------------------------------------------------------------
  # Step flow
  # -------------------------------------------------------------------

  @doc """
  Returns the onboarding step sequence.

  When `calendar_connected?` is true the conditional `:choose_theme` step is
  included (right after `:connect_calendar`); otherwise it is omitted.
  """
  @spec steps(boolean()) :: [step()]
  def steps(true), do: @steps_with_theme
  def steps(false), do: @steps_without_theme

  @doc """
  Returns the total number of steps in the given sequence.
  """
  @spec step_count([step()]) :: pos_integer()
  def step_count(steps) when is_list(steps), do: length(steps)

  @doc """
  Returns the 1-indexed position of a step within the given sequence.
  """
  @spec step_number(step(), [step()]) :: pos_integer()
  def step_number(step, steps) when is_list(steps) do
    case Enum.find_index(steps, &(&1 == step)) do
      nil -> 1
      index -> index + 1
    end
  end

  @doc """
  Validates if a given step name is one of the known steps.
  """
  @spec valid_step?(binary()) :: boolean()
  def valid_step?(step_name) when is_binary(step_name) do
    step_atom = String.to_existing_atom(step_name)
    step_atom in @all_steps
  rescue
    ArgumentError -> false
  end

  @spec valid_step?(step()) :: boolean()
  def valid_step?(step_atom) when is_atom(step_atom), do: step_atom in @all_steps

  @spec valid_step?(term()) :: boolean()
  def valid_step?(_other), do: false

  @doc """
  Checks if a step is completed based on the current position within `steps`.
  """
  @spec step_completed?(step(), step(), [step()]) :: boolean()
  def step_completed?(step, current_step, steps) when is_list(steps) do
    with index when is_integer(index) <- Enum.find_index(steps, &(&1 == step)),
         current when is_integer(current) <- Enum.find_index(steps, &(&1 == current_step)) do
      index < current
    else
      _nil -> false
    end
  end

  @doc """
  Returns the next step in `steps`, or nil if at the end.
  """
  @spec next_step(step(), [step()]) :: step() | nil
  def next_step(step, steps) when is_list(steps), do: neighbour(steps, step, 1)

  @doc """
  Returns the previous step in `steps`, or nil if at the beginning.
  """
  @spec previous_step(step(), [step()]) :: step() | nil
  def previous_step(step, steps) when is_list(steps), do: neighbour(steps, step, -1)

  defp neighbour(steps, step, delta) do
    case Enum.find_index(steps, &(&1 == step)) do
      nil ->
        nil

      index ->
        new_index = index + delta
        if new_index >= 0, do: Enum.at(steps, new_index), else: nil
    end
  end

  # -------------------------------------------------------------------
  # Step display
  # -------------------------------------------------------------------

  @doc """
  Returns the step title for display purposes.
  """
  @spec step_title(step()) :: String.t()
  def step_title(:welcome), do: "Welcome to Tymeslot"
  def step_title(:profile), do: "Set up your profile"
  def step_title(:connect_calendar), do: "Connect your calendar"
  def step_title(:choose_theme), do: "Choose your theme"
  def step_title(:buffer_time), do: "Buffer between meetings"
  def step_title(:booking_window), do: "Booking window"
  def step_title(:minimum_notice), do: "Minimum notice"
  def step_title(:ready), do: "You're all set!"

  @doc """
  Returns the step description for display purposes.
  """
  @spec step_description(step()) :: String.t()
  def step_description(:welcome), do: "Let's get you up and running in just a few steps."

  def step_description(:profile),
    do: "Add your name, photo, and a short bio so invitees know who they're booking with."

  def step_description(:connect_calendar),
    do: "Sync your calendar to avoid double-bookings and keep everything in one place."

  def step_description(:choose_theme),
    do: "Pick the look and feel of your booking page — then preview the real thing."

  def step_description(:buffer_time),
    do: "Breathing room between appointments so you never feel rushed."

  def step_description(:booking_window),
    do: "How far into the future clients can schedule with you."

  def step_description(:minimum_notice),
    do: "Prevents last-minute surprise bookings so you always have time to prepare."

  def step_description(:ready),
    do: "Your account is ready. Head to your dashboard to start scheduling."

  @doc """
  Returns the button text for the next step.
  """
  @spec next_button_text(step()) :: String.t()
  def next_button_text(:welcome), do: "Let's go"
  def next_button_text(:ready), do: "Go to dashboard"
  def next_button_text(_step), do: "Continue"

  @doc """
  Returns whether the back button should be shown for a given step.
  """
  @spec show_back_button?(step()) :: boolean()
  def show_back_button?(:welcome), do: false
  def show_back_button?(:ready), do: false
  def show_back_button?(_step), do: true

  @doc """
  Returns whether a step is a scheduling preference step.
  """
  @spec scheduling_step?(step()) :: boolean()
  def scheduling_step?(:buffer_time), do: true
  def scheduling_step?(:booking_window), do: true
  def scheduling_step?(:minimum_notice), do: true
  def scheduling_step?(_step), do: false

  # -------------------------------------------------------------------
  # Scheduling preset accessors
  # -------------------------------------------------------------------

  @spec buffer_time_options() :: [option()]
  def buffer_time_options, do: @buffer_time_options

  @spec buffer_time_values() :: [integer()]
  def buffer_time_values, do: @buffer_time_values

  @spec buffer_minutes_constraints() :: map()
  def buffer_minutes_constraints, do: @buffer_minutes_constraints

  @spec advance_booking_options() :: [option()]
  def advance_booking_options, do: @advance_booking_options

  @spec advance_booking_values() :: [integer()]
  def advance_booking_values, do: @advance_booking_values

  @spec advance_booking_constraints() :: map()
  def advance_booking_constraints, do: @advance_booking_constraints

  @spec min_advance_options() :: [option()]
  def min_advance_options, do: @min_advance_options

  @spec min_advance_values() :: [integer()]
  def min_advance_values, do: @min_advance_values

  @spec min_advance_constraints() :: map()
  def min_advance_constraints, do: @min_advance_constraints

  @doc """
  Returns custom input configuration for all scheduling preference fields.

  Maps setting names to their field configuration including:
  - field: The profile schema field atom
  - presets: List of preset values
  - constraints: Min/max/step/default values
  """
  @spec custom_input_config() :: map()
  def custom_input_config, do: @custom_input_config
end
