defmodule TymeslotWeb.Dashboard.Calendar.PanelReminderList do
  @moduledoc """
  The pieces the side panel's two reminder editors share: the reminders as
  removable chips, and the lead times and methods the add row offers. The
  New event form (`PanelNewReminders`) and an open event
  (`PanelFields.reminder_field/1`) draw their lists and add rows with them,
  so both read and offer the same values.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Calendar.ReminderForm
  alias TymeslotWeb.Components.Calendar.RemindersEditor

  attr :id, :string, default: nil
  attr :reminders, :list, required: true

  attr :remove, :any,
    default: nil,
    doc: "a function of `{reminder, index}` giving the remove `JS`; none draws no remove buttons"

  @doc "Each reminder as a chip, with a remove button when `remove` is given."
  @spec chips(map()) :: Phoenix.LiveView.Rendered.t()
  def chips(assigns) do
    ~H"""
    <ul
      :if={@reminders != []}
      id={@id}
      class="flex flex-wrap gap-1.5"
      aria-label={dgettext("dashboard_calendar_editing", "Reminders")}
    >
      <li
        :for={{reminder, index} <- Enum.with_index(@reminders)}
        class={[
          "inline-flex max-w-full items-center gap-1 rounded-token-full bg-tymeslot-100 py-0.5 pl-2.5 text-token-sm text-tymeslot-800",
          if(@remove, do: "pr-1", else: "pr-2.5")
        ]}
      >
        <span class="truncate">{RemindersEditor.reminder_label(reminder)}</span>
        <button
          :if={@remove}
          type="button"
          phx-click={@remove.({reminder, index})}
          aria-label={
            dgettext("dashboard_calendar_editing", "Remove reminder %{label}",
              label: RemindersEditor.reminder_label(reminder)
            )
          }
          class="shrink-0 rounded-token-full p-0.5 text-tymeslot-500 hover:bg-tymeslot-200 hover:text-tymeslot-800 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400 max-sm:min-h-11 max-sm:min-w-11"
        >
          <.icon name="hero-x-mark-micro" class="h-4 w-4" />
        </button>
      </li>
    </ul>
    """
  end

  @doc "The add row's lead times, as `<.select>` options."
  @spec minutes_options() :: [{String.t(), String.t()}]
  def minutes_options,
    do:
      Enum.map(
        ReminderForm.reminder_minutes_presets(),
        &{RemindersEditor.minutes_label(&1), Integer.to_string(&1)}
      )

  @doc "The add row's methods, as `<.select>` options."
  @spec method_options() :: [{String.t(), String.t()}]
  def method_options,
    do: [
      {dgettext("dashboard_calendar_events", "Notification"), "popup"},
      {dgettext("dashboard_calendar_events", "Email"), "email"}
    ]
end
