defmodule TymeslotWeb.OnboardingLive.StepConfig do
  @moduledoc """
  Configuration module for onboarding steps and related data.

  Centralizes step definitions, validation rules, and configuration
  options for the onboarding flow.
  """

  @typedoc "Represents an onboarding step in the flow."
  @type step :: :welcome | :basic_settings | :scheduling_preferences | :complete

  @typedoc "A label/value tuple used for select options."
  @type option :: {String.t(), non_neg_integer()}

  @steps [:welcome, :basic_settings, :scheduling_preferences, :complete]
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
    min: 0,
    max: 120,
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
    min: 1,
    max: 365,
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
    min: 0,
    max: 168,
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

  @doc """
  Returns the list of available onboarding steps in order.
  """
  @spec get_steps() :: [step()]
  def get_steps, do: @steps

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

  @doc """
  Returns the step title for display purposes.
  """
  @spec step_title(step()) :: String.t()
  def step_title(:welcome), do: "Welcome to Tymeslot!"
  def step_title(:basic_settings), do: "Profile Setup"
  def step_title(:scheduling_preferences), do: "Preferences"
  def step_title(:complete), do: "You're All Set!"

  @doc """
  Returns the step description for display purposes.
  """
  @spec step_description(step()) :: String.t()
  def step_description(:welcome), do: "Let's get you set up in just a few steps"
  def step_description(:basic_settings), do: "Let's personalize your account"
  def step_description(:scheduling_preferences), do: "Configure your default meeting settings"
  def step_description(:complete), do: "Your Tymeslot account is ready to launch"

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
  def next_step(:welcome), do: :basic_settings
  def next_step(:basic_settings), do: :scheduling_preferences
  def next_step(:scheduling_preferences), do: :complete
  def next_step(:complete), do: nil

  @doc """
  Returns the previous step in the flow, or nil if at the beginning.
  """
  @spec previous_step(step()) :: step() | nil
  def previous_step(:welcome), do: nil
  def previous_step(:basic_settings), do: :welcome
  def previous_step(:scheduling_preferences), do: :basic_settings
  def previous_step(:complete), do: :scheduling_preferences

  @doc """
  Returns the button text for the next step.
  """
  @spec next_button_text(step()) :: String.t()
  def next_button_text(:complete), do: "Get Started"
  def next_button_text(_step), do: "Continue"
end
