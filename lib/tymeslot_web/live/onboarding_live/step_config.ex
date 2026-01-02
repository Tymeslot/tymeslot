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

  @doc """
  Returns the list of available onboarding steps in order.
  """
  @spec get_steps() :: [step()]
  def get_steps do
    [:welcome, :basic_settings, :scheduling_preferences, :complete]
  end

  @doc """
  Validates if a given step name is valid.
  """
  @spec valid_step?(binary()) :: boolean()
  def valid_step?(step_name) when is_binary(step_name) do
    step_atom = String.to_existing_atom(step_name)
    step_atom in get_steps()
  rescue
    ArgumentError -> false
  end

  @spec valid_step?(step()) :: boolean()
  def valid_step?(step_atom) when is_atom(step_atom) do
    step_atom in get_steps()
  end

  @spec valid_step?(term()) :: boolean()
  def valid_step?(_), do: false

  @doc """
  Returns configuration for buffer time options.
  """
  @spec buffer_time_options() :: [option()]
  def buffer_time_options do
    [
      {"No buffer", 0},
      {"15 min", 15},
      {"30 min", 30},
      {"45 min", 45},
      {"60 min", 60}
    ]
  end

  @doc """
  Returns configuration for advance booking window options.
  """
  @spec advance_booking_options() :: [option()]
  def advance_booking_options do
    [
      {"1 week", 7},
      {"2 weeks", 14},
      {"1 month", 30},
      {"3 months", 90},
      {"6 months", 180},
      {"1 year", 365}
    ]
  end

  @doc """
  Returns configuration for minimum advance notice options.
  """
  @spec min_advance_options() :: [option()]
  def min_advance_options do
    [
      {"No minimum", 0},
      {"1 hour", 1},
      {"3 hours", 3},
      {"6 hours", 6},
      {"12 hours", 12},
      {"24 hours", 24},
      {"48 hours", 48}
    ]
  end

  @doc """
  Returns the step title for display purposes.
  """
  @spec step_title(step()) :: String.t()
  def step_title(:welcome), do: "Welcome to Tymeslot!"
  def step_title(:basic_settings), do: "Basic Settings"
  def step_title(:scheduling_preferences), do: "Scheduling Preferences"
  def step_title(:complete), do: "You're All Set!"

  @doc """
  Returns the step description for display purposes.
  """
  @spec step_description(step()) :: String.t()
  def step_description(:welcome), do: "Let's get you set up in just a few steps"
  def step_description(:basic_settings), do: "Let's personalize your account"
  def step_description(:scheduling_preferences), do: "Configure your default meeting settings"
  def step_description(:complete), do: "Your Tymeslot account is ready to use"

  @doc """
  Checks if a step is completed based on current step position.
  """
  @spec step_completed?(step(), step()) :: boolean()
  def step_completed?(step, current_step) do
    steps = get_steps()
    step_index = Enum.find_index(steps, &(&1 == step))
    current_index = Enum.find_index(steps, &(&1 == current_step))

    step_index < current_index
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
  def next_button_text(_), do: "Continue"
end
