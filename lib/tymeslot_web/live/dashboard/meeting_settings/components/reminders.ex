defmodule TymeslotWeb.Dashboard.MeetingSettings.Components.Reminders do
  @moduledoc "Reminder configuration component for meeting type forms."
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias Tymeslot.Utils.ReminderUtils
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Live.Shared.FormValidationHelpers

  @doc """
  Section for configuring meeting reminders.
  """
  attr :reminders, :list, required: true
  attr :new_reminder_value, :string, required: true
  attr :new_reminder_unit, :string, required: true
  attr :reminder_error, :string, required: true
  attr :show_custom_reminder, :boolean, default: false
  attr :reminder_confirmation, :string, default: nil
  attr :form_errors, :map, required: true
  attr :myself, :any, required: true

  @spec reminders_section(map()) :: Phoenix.LiveView.Rendered.t()
  def reminders_section(assigns) do
    ~H"""
    <div>
      <label class="label">
        Reminders
      </label>
      <p class="text-token-sm text-tymeslot-600">
        Add up to three reminder emails for this meeting type. We recommend using only one.
      </p>

      <div class="mt-3 flex flex-wrap items-center gap-3">
        <%= if @reminders == [] do %>
          <span class="text-token-sm text-tymeslot-500 italic">No reminders configured.</span>
        <% else %>
          <%= for reminder <- @reminders do %>
            <span class="tag-semantic tag-semantic-teal">
              {ReminderUtils.format_reminder_label(reminder.value, reminder.unit)} before
              <button
                type="button"
                phx-click={JS.push("remove_reminder",
                  value: %{value: reminder.value, unit: reminder.unit},
                  target: @myself
                )}
                class="inline-flex items-center justify-center rounded-full border border-teal-200 bg-white text-teal-600 hover:text-teal-700 hover:border-teal-300"
                aria-label="Remove reminder"
              >
                <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                </svg>
              </button>
            </span>
          <% end %>
        <% end %>
      </div>

      <div class="mt-4 space-y-3">
        <div class="flex flex-wrap items-center gap-2">
          <%!-- Quick add buttons --%>
          <%= unless Enum.any?(@reminders, &(&1.value == 30 and &1.unit == "minutes")) do %>
            <button
              type="button"
              phx-click={JS.push("add_quick_reminder", value: %{amount: 30, unit: "minutes"}, target: @myself)}
              disabled={length(@reminders) >= 3}
              title={if length(@reminders) >= 3, do: "Maximum of 3 reminders allowed", else: nil}
              class="btn-tag-selector btn-tag-selector-teal"
            >
              + 30 min. before
            </button>
          <% end %>

          <%= unless Enum.any?(@reminders, &(&1.value == 60 and &1.unit == "minutes") or (&1.value == 1 and &1.unit == "hours")) do %>
            <button
              type="button"
              phx-click={JS.push("add_quick_reminder", value: %{amount: 60, unit: "minutes"}, target: @myself)}
              disabled={length(@reminders) >= 3}
              title={if length(@reminders) >= 3, do: "Maximum of 3 reminders allowed", else: nil}
              class="btn-tag-selector btn-tag-selector-teal"
            >
              + 1 hour before
            </button>
          <% end %>

          <button
            type="button"
            phx-click="toggle_custom_reminder"
            phx-target={@myself}
            disabled={length(@reminders) >= 3}
            title={if length(@reminders) >= 3, do: "Maximum of 3 reminders allowed", else: nil}
            class={[
              "btn-tag-selector btn-tag-selector-teal",
              if(@show_custom_reminder, do: "btn-tag-selector-teal--active")
            ]}
          >
            {if @show_custom_reminder, do: "Cancel Custom", else: "Add Custom"}
          </button>

          <%= if @reminder_confirmation do %>
            <span class="text-token-sm text-teal-600 font-bold">
              ✓ {@reminder_confirmation}
            </span>
          <% end %>
        </div>

        <%= if @show_custom_reminder && length(@reminders) < 3 do %>
          <div class="flex items-center gap-2 p-3 bg-teal-50/50 rounded-token-2xl border-2 border-teal-100/50 max-w-sm animate-in slide-in-from-top-2 duration-300">
            <div class="flex-1 flex items-center gap-2">
              <input
                type="number"
                min="1"
                step="1"
                name="reminder[value]"
                value={@new_reminder_value}
                placeholder="30"
                class="input !py-1.5 !px-3 w-20 text-token-sm"
                phx-change="update_reminder_input"
                phx-target={@myself}
              />
              <select
                name="reminder[unit]"
                class="input !py-1.5 !px-3 w-28 text-token-sm"
                value={@new_reminder_unit}
                phx-change="update_reminder_input"
                phx-target={@myself}
              >
                <option value="minutes">Minutes</option>
                <option value="hours">Hours</option>
                <option value="days">Days</option>
              </select>
            </div>
            <button
              type="button"
              phx-click="add_reminder"
              phx-target={@myself}
              class="btn btn-primary btn-sm !rounded-token-lg"
            >
              Add
            </button>
          </div>
        <% end %>
      </div>

      <%= if @reminder_error do %>
        <p class="form-error mt-2">{@reminder_error}</p>
      <% end %>
      <%= for error <- FormValidationHelpers.field_errors(@form_errors, :reminder_config) do %>
        <p class="form-error mt-2">{Helpers.format_errors(error)}</p>
      <% end %>
    </div>
    """
  end
end
