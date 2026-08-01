defmodule TymeslotWeb.Dashboard.MeetingSettings.Components.Reminders do
  @moduledoc "Reminder configuration component for meeting type forms."
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

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
        {dgettext("dashboard_meeting_form", "Reminders")}
      </label>
      <p class="text-token-sm text-tymeslot-600">
        {dgettext(
          "dashboard_meeting_form",
          "Add up to three reminder emails for this meeting type. We recommend using only one."
        )}
      </p>

      <div class="mt-3 flex flex-wrap items-center gap-3">
        <%= if @reminders == [] do %>
          <span class="text-token-sm text-tymeslot-500 italic">
            {dgettext("dashboard_meeting_form", "No reminders configured.")}
          </span>
        <% else %>
          <%= for reminder <- @reminders do %>
            <span class="tag-semantic tag-semantic-turquoise">
              {dgettext("dashboard_meeting_form", "%{label} before",
                label: ReminderUtils.format_reminder_label(reminder.value, reminder.unit)
              )}
              <button
                type="button"
                phx-click={JS.push("remove_reminder",
                  value: %{value: reminder.value, unit: reminder.unit},
                  target: @myself
                )}
                class="inline-flex items-center justify-center rounded-full border border-turquoise-200 bg-white text-turquoise-600 hover:text-turquoise-700 hover:border-turquoise-300"
                aria-label={dgettext("dashboard_meeting_form", "Remove reminder")}
              >
                <.icon name="hero-x-mark" class="h-4 w-4" />
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
              title={
                if length(@reminders) >= 3,
                  do: dgettext("dashboard_meeting_form", "Maximum of 3 reminders allowed"),
                  else: nil
              }
              class="btn-tag-selector btn-tag-selector-turquoise"
            >
              + {dgettext("dashboard_meeting_form", "30 min. before")}
            </button>
          <% end %>

          <%= unless Enum.any?(@reminders, &(&1.value == 60 and &1.unit == "minutes") or (&1.value == 1 and &1.unit == "hours")) do %>
            <button
              type="button"
              phx-click={JS.push("add_quick_reminder", value: %{amount: 60, unit: "minutes"}, target: @myself)}
              disabled={length(@reminders) >= 3}
              title={
                if length(@reminders) >= 3,
                  do: dgettext("dashboard_meeting_form", "Maximum of 3 reminders allowed"),
                  else: nil
              }
              class="btn-tag-selector btn-tag-selector-turquoise"
            >
              + {dgettext("dashboard_meeting_form", "1 hour before")}
            </button>
          <% end %>

          <button
            type="button"
            phx-click="toggle_custom_reminder"
            phx-target={@myself}
            disabled={length(@reminders) >= 3}
            title={
              if length(@reminders) >= 3,
                do: dgettext("dashboard_meeting_form", "Maximum of 3 reminders allowed"),
                else: nil
            }
            class={[
              "btn-tag-selector btn-tag-selector-turquoise",
              if(@show_custom_reminder, do: "btn-tag-selector-turquoise--active")
            ]}
          >
            {if @show_custom_reminder,
              do: dgettext("dashboard_meeting_form", "Cancel Custom"),
              else: dgettext("dashboard_meeting_form", "Add Custom")}
          </button>

          <%= if @reminder_confirmation do %>
            <span class="text-token-sm text-turquoise-600 font-bold">
              ✓ {@reminder_confirmation}
            </span>
          <% end %>
        </div>

        <%= if @show_custom_reminder && length(@reminders) < 3 do %>
          <div class="flex items-center gap-2 p-3 bg-turquoise-50/50 rounded-token-2xl border-2 border-turquoise-100/50 max-w-sm animate-in slide-in-from-top-2 duration-300">
            <div class="flex-1 flex items-center gap-2">
              <input
                type="number"
                min="1"
                step="1"
                name="reminder[value]"
                value={@new_reminder_value}
                placeholder="30"
                class="input py-1.5! px-3! w-20 text-token-sm"
                phx-change="update_reminder_input"
                phx-target={@myself}
              />
              <select
                name="reminder[unit]"
                class="input py-1.5! px-3! w-28 text-token-sm"
                value={@new_reminder_unit}
                phx-change="update_reminder_input"
                phx-target={@myself}
              >
                <option value="minutes">{dgettext("dashboard_meeting_form", "Minutes")}</option>
                <option value="hours">{dgettext("dashboard_meeting_form", "Hours")}</option>
                <option value="days">{dgettext("dashboard_meeting_form", "Days")}</option>
              </select>
            </div>
            <button
              type="button"
              phx-click="add_reminder"
              phx-target={@myself}
              class="btn btn-primary btn-sm rounded-token-lg!"
            >
              {dgettext("dashboard_meeting_form", "Add")}
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
