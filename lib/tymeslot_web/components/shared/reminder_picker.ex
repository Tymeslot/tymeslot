defmodule TymeslotWeb.Components.Shared.ReminderPicker do
  @moduledoc """
  Reminder picker shared by the surfaces that decide when Tymeslot emails a
  reminder: the meeting type form and the calendar's quick-add meeting.

  Both hold the same thing — a list of `%{value: integer, unit: "minutes" |
  "hours" | "days"}` reminders, capped by `ReminderValidation.max_reminders/0`
  and checked by `ReminderValidation.check_policy/2` — so both offer the same
  control: the two lead times most reminders use as one-click buttons, and a
  custom value with its unit for anything else.

  The owning LiveComponent keeps the picker's state (the list, the custom
  input's value and unit, whether the custom row is open, the last error and
  confirmation) and receives the picker's events through `phx-target`. Event
  names are prefixed with `event_prefix` so a component that already answers
  to `add_reminder` for something else can namespace them; the names are
  otherwise `add_quick_reminder`, `toggle_custom_reminder`,
  `update_reminder_input`, `add_reminder` and `remove_reminder`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

  alias Phoenix.LiveView.JS
  alias Tymeslot.MeetingTypes.ReminderValidation
  alias Tymeslot.Utils.ReminderUtils

  @doc """
  The reminder picker.

  `description` is the caller's own one-line explanation of what the reminders
  being configured will do — a meeting type and a single quick-added meeting
  word that differently — and `extra_errors` are messages from the caller's own
  validation, shown below the picker's.
  """
  attr :reminders, :list, required: true
  attr :max_reminders, :integer, required: true
  attr :new_reminder_value, :string, required: true
  attr :new_reminder_unit, :string, required: true
  attr :reminder_error, :string, required: true
  attr :description, :string, required: true
  attr :show_custom_reminder, :boolean, default: false
  attr :reminder_confirmation, :string, default: nil
  attr :extra_errors, :list, default: []
  attr :event_prefix, :string, default: ""
  attr :myself, :any, required: true

  @spec reminder_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def reminder_picker(assigns) do
    assigns =
      assign(assigns, :limit_reached?, length(assigns.reminders) >= assigns.max_reminders)

    ~H"""
    <section class="space-y-2">
      <div class="flex items-center gap-2">
        <.icon name="hero-bell" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-800">
          {dgettext("common", "Reminders")}
        </h3>
      </div>
      <p class="text-token-sm text-tymeslot-600">{@description}</p>

      <div class="mt-3 flex flex-wrap items-center gap-3">
        <%= if @reminders == [] do %>
          <span class="text-token-sm text-tymeslot-500 italic">
            {dgettext("common", "No reminders configured.")}
          </span>
        <% else %>
          <%= for reminder <- @reminders do %>
            <span class="tag-semantic tag-semantic-turquoise">
              {dgettext("common", "%{label} before", label: reminder_label(reminder))}
              <button
                type="button"
                phx-click={
                  JS.push(@event_prefix <> "remove_reminder",
                    value: %{value: reminder.value, unit: reminder.unit},
                    target: @myself
                  )
                }
                data-testid="reminder-remove"
                class="inline-flex items-center justify-center rounded-full border border-turquoise-200 bg-white text-turquoise-600 hover:text-turquoise-700 hover:border-turquoise-300"
                aria-label={dgettext("common", "Remove reminder")}
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
              phx-click={
                JS.push(@event_prefix <> "add_quick_reminder",
                  value: %{amount: 30, unit: "minutes"},
                  target: @myself
                )
              }
              data-testid="reminder-preset-30-minutes"
              disabled={@limit_reached?}
              title={limit_title(@limit_reached?, @max_reminders)}
              class="btn-tag-selector btn-tag-selector-turquoise"
            >
              + {dgettext("common", "30 min. before")}
            </button>
          <% end %>

          <%= unless Enum.any?(@reminders, &(&1.value == 60 and &1.unit == "minutes") or (&1.value == 1 and &1.unit == "hours")) do %>
            <button
              type="button"
              phx-click={
                JS.push(@event_prefix <> "add_quick_reminder",
                  value: %{amount: 60, unit: "minutes"},
                  target: @myself
                )
              }
              data-testid="reminder-preset-60-minutes"
              disabled={@limit_reached?}
              title={limit_title(@limit_reached?, @max_reminders)}
              class="btn-tag-selector btn-tag-selector-turquoise"
            >
              + {dgettext("common", "1 hour before")}
            </button>
          <% end %>

          <button
            type="button"
            phx-click={@event_prefix <> "toggle_custom_reminder"}
            phx-target={@myself}
            data-testid="reminder-custom-toggle"
            disabled={@limit_reached?}
            title={limit_title(@limit_reached?, @max_reminders)}
            class={[
              "btn-tag-selector btn-tag-selector-turquoise",
              if(@show_custom_reminder, do: "btn-tag-selector-turquoise--active")
            ]}
          >
            {if @show_custom_reminder,
              do: dgettext("common", "Cancel Custom"),
              else: dgettext("common", "Add Custom")}
          </button>

          <%= if @reminder_confirmation do %>
            <span class="text-token-sm text-turquoise-600 font-bold">
              ✓ {@reminder_confirmation}
            </span>
          <% end %>
        </div>

        <%= if @show_custom_reminder && !@limit_reached? do %>
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
                phx-change={@event_prefix <> "update_reminder_input"}
                phx-target={@myself}
              />
              <select
                name="reminder[unit]"
                class="input py-1.5! px-3! w-28 text-token-sm"
                value={@new_reminder_unit}
                phx-change={@event_prefix <> "update_reminder_input"}
                phx-target={@myself}
              >
                <option value="minutes">{dgettext("common", "Minutes")}</option>
                <option value="hours">{dgettext("common", "Hours")}</option>
                <option value="days">{dgettext("common", "Days")}</option>
              </select>
            </div>
            <button
              type="button"
              phx-click={@event_prefix <> "add_reminder"}
              phx-target={@myself}
              data-testid="reminder-custom-add"
              class="btn btn-primary btn-sm rounded-token-lg!"
            >
              {dgettext("common", "Add")}
            </button>
          </div>
        <% end %>
      </div>

      <%= if @reminder_error do %>
        <p class="form-error mt-2">{@reminder_error}</p>
      <% end %>
      <%= for error <- @extra_errors do %>
        <p class="form-error mt-2">{error}</p>
      <% end %>
    </section>
    """
  end

  @doc """
  A reminder's lead time in the reader's own language: "30 minutes",
  "1 Stunde", "5 хвилин".

  `ReminderUtils.format_reminder_label/2` builds the same label from English
  words, which is right for anything machine-facing but reached the screen
  here — a German organiser was shown "30 minutes vorher", half translated.
  The unit word is a plural form rather than a lookup, so a language that
  inflects after a number ("1 minutu", "2 minuty", "5 minut") can say it
  properly, while the sentences around it ("%{label} before", "Added %{label}
  before") stay one msgid each.
  """
  @spec reminder_label(%{value: integer() | String.t(), unit: String.t()}) :: String.t()
  def reminder_label(%{value: value, unit: unit}) do
    value = ReminderUtils.parse_reminder_value(value)

    case ReminderUtils.normalize_reminder_unit(unit) do
      "hours" -> dngettext("common", "%{count} hour", "%{count} hours", value)
      "days" -> dngettext("common", "%{count} day", "%{count} days", value)
      _minutes -> dngettext("common", "%{count} minute", "%{count} minutes", value)
    end
  end

  @doc """
  Validates a reminder about to be added to `reminders` and returns
  `{:ok, reminder}` or `{:error, message}`.

  The input checks are the picker's own; whether the resulting list is allowed
  is `ReminderValidation.check_policy/2`, the same rule the save path applies,
  so a reminder accepted here cannot later block what holds it from saving.
  The reminders already in the list are passed as held, so the year limit
  judges the one being added and not a longer one saved before the limit.
  """
  @spec validate_new_reminder(list(), any(), any()) :: {:ok, map()} | {:error, String.t()}
  def validate_new_reminder(reminders, value, unit) do
    cond do
      is_nil(value) or value == "" ->
        {:error, dgettext("common", "Reminder value is required")}

      match?({:error, _reason}, ReminderUtils.validate_reminder_value(value)) ->
        {:error, dgettext("common", "Reminder value must be a positive number")}

      unit not in ["minutes", "hours", "days"] ->
        {:error, dgettext("common", "Select a valid reminder unit")}

      true ->
        reminder = %{value: ReminderUtils.parse_reminder_value(value), unit: unit}

        case ReminderValidation.check_policy(reminders ++ [reminder], reminders) do
          :ok -> {:ok, reminder}
          {:error, reason} -> {:error, policy_message(reason)}
        end
    end
  end

  # --- Private helpers ---

  defp policy_message(:too_many) do
    dngettext(
      "common",
      "You can configure up to %{count} reminder",
      "You can configure up to %{count} reminders",
      ReminderValidation.max_reminders()
    )
  end

  defp policy_message(:duplicate),
    do: dgettext("common", "This reminder already exists")

  defp policy_message(:exceeds_max),
    do: dgettext("common", "Reminders cannot be set for more than 1 year in advance")

  # The tooltip explaining why an add button is disabled. Nil while more
  # reminders can still be added, so an enabled button carries no title.
  @spec limit_title(boolean(), pos_integer()) :: String.t() | nil
  defp limit_title(false, _max_reminders), do: nil

  defp limit_title(true, max_reminders) do
    dngettext(
      "common",
      "Maximum of %{count} reminder allowed",
      "Maximum of %{count} reminders allowed",
      max_reminders
    )
  end
end
