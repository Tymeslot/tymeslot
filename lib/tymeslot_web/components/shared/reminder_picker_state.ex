defmodule TymeslotWeb.Components.Shared.ReminderPickerState do
  @moduledoc """
  The state behind `TymeslotWeb.Components.Shared.ReminderPicker`, as a plain
  map its owners can keep wherever they already keep their own.

  The meeting type form holds it in the LiveComponent's assigns; the calendar's
  create modal holds it inside `creating_event`, next to the rest of the form
  being filled in. Neither reimplements what adding a reminder means, so a rule
  added here — a new unit, a different cap — reaches both surfaces at once.

  Each mutation answers `{:ok, state}` when the reminder list changed and
  `{:noop, state}` when it did not, so an owner that autosaves on change knows
  whether this was one. A rejected reminder leaves its message in
  `:reminder_error` and the list untouched.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.ReminderUtils
  alias TymeslotWeb.Components.Shared.ReminderPicker

  @type t :: %{
          reminders: [map()],
          new_reminder_value: String.t(),
          new_reminder_unit: String.t(),
          reminder_error: String.t() | nil,
          show_custom_reminder: boolean(),
          reminder_confirmation: String.t() | nil
        }

  @doc """
  A picker holding `reminders`, with the custom row closed and nothing to say.
  """
  @spec new([map()]) :: t()
  def new(reminders \\ []) do
    %{
      reminders: reminders,
      new_reminder_value: "",
      new_reminder_unit: "minutes",
      reminder_error: nil,
      show_custom_reminder: false,
      reminder_confirmation: nil
    }
  end

  @doc """
  Records what the custom row's number and unit currently hold.

  Either field may be missing from `params`: the two inputs post separately, so
  the one that did not change keeps what it had.
  """
  @spec update_input(t(), map()) :: {:noop, t()}
  def update_input(state, %{"reminder" => params}) do
    {:noop,
     %{
       state
       | new_reminder_value: Map.get(params, "value", state.new_reminder_value),
         new_reminder_unit: Map.get(params, "unit", state.new_reminder_unit),
         reminder_error: nil
     }}
  end

  def update_input(state, _params), do: {:noop, state}

  @doc "Opens or closes the custom row."
  @spec toggle_custom(t()) :: {:noop, t()}
  def toggle_custom(state) do
    {:noop,
     %{state | show_custom_reminder: !state.show_custom_reminder, reminder_confirmation: nil}}
  end

  @doc """
  Adds one of the preset lead times, as posted by a quick-add button.
  """
  @spec add_quick(t(), map()) :: {:ok, t()} | {:noop, t()}
  def add_quick(state, %{"amount" => amount, "unit" => unit}), do: add(state, amount, unit)
  def add_quick(state, _params), do: add(state, nil, nil)

  @doc """
  Adds what the custom row holds, closing it and clearing its number on success.

  `params` are the row's own fields when the add arrives as a form submit, and
  are preferred over what the last `phx-change` recorded: a submit carries the
  current values whether or not a change event for them landed first.
  """
  @spec add_custom(t(), map()) :: {:ok, t()} | {:noop, t()}
  def add_custom(state, params \\ %{}) do
    submitted = Map.get(params, "reminder", %{})
    value = Map.get(submitted, "value") || state.new_reminder_value
    unit = Map.get(submitted, "unit") || state.new_reminder_unit

    case add(state, value, unit) do
      {:ok, added} -> {:ok, %{added | new_reminder_value: "", show_custom_reminder: false}}
      {:noop, rejected} -> {:noop, rejected}
    end
  end

  @doc """
  Removes the reminder the given value and unit name, whether they arrive as a
  `JS.push` payload or as individual `phx-value-*` params.
  """
  @spec remove(t(), map()) :: {:ok, t()} | {:noop, t()}
  def remove(state, params) do
    {value, unit} =
      case params do
        %{"value" => %{"value" => value, "unit" => unit}} -> {value, unit}
        %{"value" => value, "unit" => unit} -> {value, unit}
        _other -> {nil, nil}
      end

    remaining =
      Enum.reject(state.reminders, fn reminder ->
        reminder.value == ReminderUtils.parse_reminder_value(value) and reminder.unit == unit
      end)

    {:ok, %{state | reminders: remaining, reminder_error: nil}}
  end

  @doc "Forgets the confirmation shown after the last reminder was added."
  @spec clear_confirmation(t()) :: t()
  def clear_confirmation(state), do: %{state | reminder_confirmation: nil}

  # --- Private helpers ---

  defp add(state, value, unit) do
    case ReminderPicker.validate_new_reminder(state.reminders, value, unit) do
      {:ok, reminder} ->
        {:ok,
         %{
           state
           | reminders: state.reminders ++ [reminder],
             reminder_error: nil,
             reminder_confirmation: confirmation(reminder)
         }}

      {:error, message} ->
        {:noop, %{state | reminder_error: message}}
    end
  end

  defp confirmation(reminder) do
    dgettext("common", "Added %{label} before",
      label: ReminderUtils.format_reminder_label(reminder.value, reminder.unit)
    )
  end
end
