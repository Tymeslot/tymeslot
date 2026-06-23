defmodule TymeslotWeb.OnboardingLive.StepConfig do
  @moduledoc """
  Configuration module for onboarding steps and related data.

  Centralises step definitions, validation rules, and configuration
  options for the seven-step onboarding flow:
  welcome → profile → connect_calendar → buffer_time → booking_window → minimum_notice → ready.
  """

  @typedoc "Represents an onboarding step in the flow."
  @type step ::
          :welcome
          | :profile
          | :connect_calendar
          | :buffer_time
          | :booking_window
          | :minimum_notice
          | :ready

  @typedoc "A label/value tuple used for select options."
  @type option :: {String.t(), non_neg_integer()}

  alias Tymeslot.Validation.Constraints

  @steps [
    :welcome,
    :profile,
    :connect_calendar,
    :buffer_time,
    :booking_window,
    :minimum_notice,
    :ready
  ]
  @step_index Map.new(Enum.with_index(@steps))

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
  Returns the list of available onboarding steps in order.
  """
  @spec get_steps() :: [step()]
  def get_steps, do: @steps

  @doc """
  Returns the total number of onboarding steps.
  """
  @spec step_count() :: pos_integer()
  def step_count, do: length(@steps)

  @doc """
  Returns the 1-indexed position of a step in the flow.
  """
  @spec step_number(step()) :: pos_integer()
  def step_number(step), do: @step_index[step] + 1

  @doc """
  Validates if a given step name is valid.
  """
  @spec valid_step?(binary()) :: boolean()
  def valid_step?(step_name) when is_binary(step_name) do
    step_atom = String.to_existing_atom(step_name)
    step_atom in @steps
  rescue
    ArgumentError -> false
  end

  @spec valid_step?(step()) :: boolean()
  def valid_step?(step_atom) when is_atom(step_atom), do: step_atom in @steps

  @spec valid_step?(term()) :: boolean()
  def valid_step?(_other), do: false

  @doc """
  Checks if a step is completed based on current step position.
  """
  @spec step_completed?(step(), step()) :: boolean()
  def step_completed?(step, current_step) do
    @step_index[step] < @step_index[current_step]
  end

  @doc """
  Returns the next step in the flow, or nil if at the end.
  """
  @spec next_step(step()) :: step() | nil
  def next_step(:welcome), do: :profile
  def next_step(:profile), do: :connect_calendar
  def next_step(:connect_calendar), do: :buffer_time
  def next_step(:buffer_time), do: :booking_window
  def next_step(:booking_window), do: :minimum_notice
  def next_step(:minimum_notice), do: :ready
  def next_step(:ready), do: nil

  @doc """
  Returns the previous step in the flow, or nil if at the beginning.
  """
  @spec previous_step(step()) :: step() | nil
  def previous_step(:welcome), do: nil
  def previous_step(:profile), do: :welcome
  def previous_step(:connect_calendar), do: :profile
  def previous_step(:buffer_time), do: :connect_calendar
  def previous_step(:booking_window), do: :buffer_time
  def previous_step(:minimum_notice), do: :booking_window
  def previous_step(:ready), do: :minimum_notice

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

  @doc """
  Returns the illustration SVG filename for a given step.
  """
  @spec illustration_file(step()) :: String.t()
  def illustration_file(:welcome), do: "welcome.svg"
  def illustration_file(:profile), do: "profile.svg"
  def illustration_file(:connect_calendar), do: "calendar-sync.svg"
  def illustration_file(:buffer_time), do: "preferences.svg"
  def illustration_file(:booking_window), do: "preferences.svg"
  def illustration_file(:minimum_notice), do: "preferences.svg"
  def illustration_file(:ready), do: "ready.svg"

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
