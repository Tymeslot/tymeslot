defmodule TymeslotWeb.OnboardingLive.SchedulingHandlers do
  @moduledoc """
  Scheduling preferences event handlers for the onboarding flow.

  Handles validation and updates for scheduling preferences including
  buffers before and after meetings, advance booking window, and minimum advance notice.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Tymeslot.Profiles.Settings
  alias TymeslotWeb.CustomInputModeHelper
  alias TymeslotWeb.OnboardingLive.StepConfig

  @doc """
  Handles validation of scheduling preferences.

  Validates scheduling preference input in real-time.
  """
  @spec handle_validate_scheduling_preferences(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_validate_scheduling_preferences(params, socket) do
    {_valid_params, errors} = validate_scheduling_preferences(params)
    {:noreply, Component.assign(socket, :form_errors, errors)}
  end

  @doc """
  Handles updating scheduling preferences in the database.

  Validates and persists scheduling preference settings. The buffers, booking
  window and minimum notice live on the profile's default availability
  schedule, so the updated schedule is what gets assigned back.
  """
  @spec handle_update_scheduling_preferences(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_scheduling_preferences(params, socket) do
    {socket, _saved_params} = save_preferences(params, socket)
    {:noreply, socket}
  end

  @doc """
  Updates scheduling preferences and syncs the custom-input mode of every field
  that was saved. Combines the persistence step with its custom-input
  bookkeeping so the LiveView delegates a single call.
  """
  @spec handle_update_with_custom_modes(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_with_custom_modes(params, socket) do
    {socket, saved_params} = save_preferences(params, socket)
    {:noreply, update_custom_input_modes(socket, saved_params, params)}
  end

  @doc """
  Seeds and reveals the custom-value input for a scheduling field, switching it
  into custom mode (unless the seeded value could not be saved).
  """
  @spec handle_focus_custom_input(String.t(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_focus_custom_input(setting, socket) do
    with %{} = config <- StepConfig.custom_input_config()[setting],
         %{} = schedule <- socket.assigns[:availability_schedule] do
      current = Map.get(schedule, config.field) || config.constraints.default_custom

      custom_value =
        if current in config.presets, do: config.constraints.default_custom, else: current

      {socket, saved_params} = save_preferences(%{setting => to_string(custom_value)}, socket)

      if Map.has_key?(saved_params, setting) do
        {:noreply, CustomInputModeHelper.enable_custom_mode(socket, config.field)}
      else
        {:noreply, socket}
      end
    else
      _other -> {:noreply, socket}
    end
  end

  # One step can hold several fields (the buffer step has two), and a change
  # may submit any of them. Each submitted field is judged on its own: the
  # valid ones are saved and the invalid ones get an error, so a bad value in
  # one field never holds back its sibling. A field's outcome replaces its own
  # error alone, so an unsaved value in a field that was not submitted keeps
  # its error. Returns the params that were saved.
  #
  # A rejected value is kept in `rejected_inputs` beside its error, so the
  # field goes on showing what was typed rather than the saved value: a
  # re-render caused by the sibling field would otherwise put the saved value
  # back into the input under an error that no longer describes it.
  defp save_preferences(params, socket) do
    {valid_params, errors} = validate_scheduling_preferences(params)
    submitted = submitted_error_keys(params)

    rejected =
      for {key, error_key, _label} <- fields(), Map.has_key?(errors, error_key), into: %{} do
        {error_key, params[key]}
      end

    socket
    |> Component.assign(:form_errors, merge_outcome(socket, :form_errors, submitted, errors))
    |> Component.assign(
      :rejected_inputs,
      merge_outcome(socket, :rejected_inputs, submitted, rejected)
    )
    |> persist(valid_params)
  end

  defp persist(socket, valid_params) when map_size(valid_params) == 0, do: {socket, %{}}

  defp persist(socket, valid_params) do
    case Settings.update_scheduling_preferences(socket.assigns.profile, valid_params) do
      {:ok, schedule} ->
        {Component.assign(socket, :availability_schedule, schedule), valid_params}

      {:error, _reason} ->
        socket =
          LiveView.put_flash(
            socket,
            :error,
            dgettext("onboarding_wizard", "Please check your input and try again.")
          )

        {socket, %{}}
    end
  end

  defp submitted_error_keys(params),
    do: for({key, error_key, _label} <- fields(), Map.has_key?(params, key), do: error_key)

  # Replaces the submitted fields' entries in a per-field assign with this
  # submission's outcome, leaving the other fields' entries as they were.
  defp merge_outcome(socket, assign, submitted, outcome) do
    socket.assigns
    |> Map.get(assign, %{})
    |> Map.drop(submitted)
    |> Map.merge(outcome)
  end

  # Private helpers

  # `params` is the whole submission, which carries the `_preset` marker that
  # tells a preset click from a custom value.
  defp update_custom_input_modes(socket, saved_params, params) do
    Enum.reduce(saved_params, socket, fn {key, value}, acc ->
      field = field_key_to_atom(key)
      if field, do: try_update_mode(acc, field, value, params), else: acc
    end)
  end

  defp field_key_to_atom("buffer_before_minutes"), do: :buffer_before_minutes
  defp field_key_to_atom("buffer_after_minutes"), do: :buffer_after_minutes
  defp field_key_to_atom("advance_booking_days"), do: :advance_booking_days
  defp field_key_to_atom("min_advance_hours"), do: :min_advance_hours
  defp field_key_to_atom(_arg), do: nil

  defp try_update_mode(socket, field, value_str, params) when is_binary(value_str) do
    case Integer.parse(value_str) do
      {int_value, _value} ->
        CustomInputModeHelper.toggle_custom_mode(socket, field, params, int_value)

      _other ->
        socket
    end
  end

  defp try_update_mode(socket, _field, _value, _params), do: socket

  defp fields do
    [
      {"buffer_before_minutes", :buffer_before_minutes,
       dgettext("onboarding_wizard", "Buffer before")},
      {"buffer_after_minutes", :buffer_after_minutes,
       dgettext("onboarding_wizard", "Buffer after")},
      {"advance_booking_days", :advance_booking_days,
       dgettext("onboarding_wizard", "Advance booking days")},
      {"min_advance_hours", :min_advance_hours,
       dgettext("onboarding_wizard", "Minimum advance hours")}
    ]
  end

  # Splits the submitted fields into the ones that pass, keyed as submitted,
  # and an error per field that does not.
  defp validate_scheduling_preferences(params) do
    config = StepConfig.custom_input_config()

    Enum.reduce(fields(), {%{}, %{}}, fn {key, error_key, label}, {valid, errors} ->
      case Map.fetch(params, key) do
        {:ok, value} ->
          case validate_field(value, config[key].constraints, error_key, label) do
            :ok -> {Map.put(valid, key, value), errors}
            {:error, error} -> {valid, Map.put(errors, error_key, error)}
          end

        :error ->
          {valid, errors}
      end
    end)
  end

  defp validate_field(value, constraints, error_key, label) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} ->
        validate_field(int, constraints, error_key, label)

      _other ->
        {:error, dgettext("onboarding_wizard", "%{field} must be a valid number", field: label)}
    end
  end

  defp validate_field(value, %{min: min, max: max}, error_key, label) when is_integer(value) do
    if value >= min and value <= max,
      do: :ok,
      else: {:error, range_error(error_key, label, min, max)}
  end

  defp validate_field(_value, _constraints, _error_key, label),
    do: {:error, dgettext("onboarding_wizard", "%{field} must be a number", field: label)}

  # The buffer fields name their unit in a whole-sentence message of their own.
  defp range_error(:buffer_before_minutes, _label, min, max),
    do:
      dgettext("onboarding_wizard", "Buffer before must be between %{min} and %{max} minutes.",
        min: min,
        max: max
      )

  defp range_error(:buffer_after_minutes, _label, min, max),
    do:
      dgettext("onboarding_wizard", "Buffer after must be between %{min} and %{max} minutes.",
        min: min,
        max: max
      )

  defp range_error(_error_key, label, min, max),
    do:
      dgettext(
        "onboarding_wizard",
        "%{field} must be between %{min} and %{max}",
        field: label,
        min: min,
        max: max
      )
end
