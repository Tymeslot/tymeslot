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

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.CustomInputModeHelper

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

  # String forms of the same list, so a URL segment can be checked without
  # converting user-supplied text into an atom.
  @all_step_names Enum.map(@all_steps, &Atom.to_string/1)

  @buffer_minutes_constraints %{
    min: Constraints.buffer_minutes_range().first,
    max: Constraints.buffer_minutes_range().last,
    step: 5,
    default_custom: 20,
    unit: "min",
    color: "turquoise"
  }

  @advance_booking_constraints %{
    min: Constraints.advance_booking_days_range().first,
    max: Constraints.advance_booking_days_range().last,
    step: 1,
    default_custom: 120,
    unit: "days",
    color: "cyan"
  }

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
      constraints: @buffer_minutes_constraints
    },
    "advance_booking_days" => %{
      field: :advance_booking_days,
      constraints: @advance_booking_constraints
    },
    "min_advance_hours" => %{
      field: :min_advance_hours,
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
    step_name in @all_step_names
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
  def step_title(:welcome), do: dgettext("onboarding_wizard", "Welcome to Tymeslot")
  def step_title(:profile), do: dgettext("onboarding_wizard", "Set up your profile")
  def step_title(:connect_calendar), do: dgettext("onboarding_wizard", "Connect your calendar")
  def step_title(:choose_theme), do: dgettext("onboarding_wizard", "Choose your theme")
  def step_title(:buffer_time), do: dgettext("onboarding_wizard", "Buffer between meetings")
  def step_title(:booking_window), do: dgettext("onboarding_wizard", "Booking window")
  def step_title(:minimum_notice), do: dgettext("onboarding_wizard", "Minimum notice")
  def step_title(:ready), do: dgettext("onboarding_wizard", "You're all set!")

  @doc """
  Returns the step description for display purposes.
  """
  @spec step_description(step()) :: String.t()
  def step_description(:welcome),
    do: dgettext("onboarding_wizard", "Let's get you up and running in just a few steps.")

  def step_description(:profile),
    do:
      dgettext(
        "onboarding_wizard",
        "Add your name, photo, and a short bio so invitees know who they're booking with."
      )

  def step_description(:connect_calendar),
    do:
      dgettext(
        "onboarding_wizard",
        "Sync your calendar to avoid double-bookings and keep everything in one place."
      )

  def step_description(:choose_theme),
    do:
      dgettext(
        "onboarding_wizard",
        "Pick the look and feel of your booking page - then preview the real thing."
      )

  def step_description(:buffer_time),
    do:
      dgettext(
        "onboarding_wizard",
        "Breathing room between appointments so you never feel rushed."
      )

  def step_description(:booking_window),
    do: dgettext("onboarding_wizard", "How far into the future clients can schedule with you.")

  def step_description(:minimum_notice),
    do:
      dgettext(
        "onboarding_wizard",
        "Prevents last-minute surprise bookings so you always have time to prepare."
      )

  def step_description(:ready),
    do:
      dgettext(
        "onboarding_wizard",
        "Your account is ready. Head to your dashboard to start scheduling."
      )

  @doc """
  Returns the button text for the next step.
  """
  @spec next_button_text(step()) :: String.t()
  def next_button_text(:welcome), do: dgettext("onboarding_wizard", "Let's go")
  def next_button_text(:ready), do: dgettext("onboarding_wizard", "Go to dashboard")
  def next_button_text(_step), do: dgettext("onboarding_wizard", "Continue")

  @doc """
  Returns whether the back button should be shown for a given step.
  """
  @spec show_back_button?(step()) :: boolean()
  def show_back_button?(:welcome), do: false
  def show_back_button?(:ready), do: false
  def show_back_button?(_step), do: true

  # -------------------------------------------------------------------
  # Scheduling preset accessors
  # -------------------------------------------------------------------

  # The wizard offers exactly the values `CustomInputModeHelper` validates a
  # preset click against, so a tag here can never be read as client tampering.
  # Only the labels are the wizard's own; the dashboard availability card words
  # the same values differently and in its own gettext domain.
  @spec buffer_time_options() :: [option()]
  def buffer_time_options, do: options(:buffer_minutes, &buffer_time_label/1)

  @spec buffer_minutes_constraints() :: map()
  def buffer_minutes_constraints, do: @buffer_minutes_constraints

  @spec advance_booking_options() :: [option()]
  def advance_booking_options, do: options(:advance_booking_days, &advance_booking_label/1)

  @spec advance_booking_constraints() :: map()
  def advance_booking_constraints, do: @advance_booking_constraints

  @spec min_advance_options() :: [option()]
  def min_advance_options, do: options(:min_advance_hours, &min_advance_label/1)

  @spec min_advance_constraints() :: map()
  def min_advance_constraints, do: @min_advance_constraints

  defp options(field, label_fun) do
    field
    |> CustomInputModeHelper.presets()
    |> Enum.map(&{label_fun.(&1), &1})
  end

  defp buffer_time_label(0), do: dgettext("onboarding_wizard", "No buffer")

  defp buffer_time_label(minutes),
    do: dgettext("onboarding_wizard", "%{minutes} min", minutes: minutes)

  defp advance_booking_label(7), do: dgettext("onboarding_wizard", "1 week")
  defp advance_booking_label(14), do: dgettext("onboarding_wizard", "2 weeks")
  defp advance_booking_label(30), do: dgettext("onboarding_wizard", "1 month")
  defp advance_booking_label(60), do: dgettext("onboarding_wizard", "2 months")
  defp advance_booking_label(90), do: dgettext("onboarding_wizard", "3 months")
  defp advance_booking_label(180), do: dgettext("onboarding_wizard", "6 months")
  defp advance_booking_label(365), do: dgettext("onboarding_wizard", "1 year")

  defp min_advance_label(0), do: dgettext("onboarding_wizard", "No minimum")
  defp min_advance_label(168), do: dgettext("onboarding_wizard", "1 week")

  defp min_advance_label(hours),
    do: dngettext("onboarding_wizard", "%{count} hour", "%{count} hours", hours)

  @doc """
  Returns custom input configuration for all scheduling preference fields.

  Maps setting names to their field configuration including:
  - field: The profile schema field atom
  - presets: List of preset values, from `CustomInputModeHelper`
  - constraints: Min/max/step/default values
  """
  @spec custom_input_config() :: map()
  def custom_input_config do
    Map.new(@custom_input_config, fn {setting, config} ->
      {setting, Map.put(config, :presets, CustomInputModeHelper.presets(config.field))}
    end)
  end
end
