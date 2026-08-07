defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.ShortcutsHelpModal do
  @moduledoc "Keyboard shortcuts help overlay for the calendar grid."

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :myself, :any, required: true

  @spec shortcuts_help_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def shortcuts_help_modal(assigns) do
    assigns = assign(assigns, :groups, shortcut_groups())

    ~H"""
    <.modal
      id="calendar-shortcuts-help-modal"
      show={true}
      on_cancel={JS.push("toggle_shortcuts_help", target: @myself)}
      size={:medium}
    >
      <:header>{dgettext("dashboard_calendar_events", "Keyboard shortcuts")}</:header>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-x-8 gap-y-6">
        <div :for={{title, shortcuts} <- @groups}>
          <h4 class="text-token-xs font-semibold text-tymeslot-500 uppercase tracking-wide mb-3">
            {title}
          </h4>
          <ul class="space-y-2">
            <li
              :for={{keys, description} <- shortcuts}
              class="flex items-center justify-between gap-3"
            >
              <span class="text-token-sm text-tymeslot-700">{description}</span>
              <span class="flex items-center gap-1 shrink-0">
                <kbd
                  :for={key <- keys}
                  class="inline-flex items-center justify-center min-w-[24px] px-1.5 py-0.5 text-token-xs font-semibold text-tymeslot-600 bg-tymeslot-50 border border-tymeslot-200 rounded-token-sm shadow-sm"
                >{key}</kbd>
              </span>
            </li>
          </ul>
        </div>
      </div>
    </.modal>
    """
  end

  defp shortcut_groups do
    [
      {dgettext("dashboard_calendar_events", "Navigation"),
       [
         {["→", "n"], dgettext("dashboard_calendar_events", "Next period")},
         {["←", "p"], dgettext("dashboard_calendar_events", "Previous period")},
         {["t"], dgettext("dashboard_calendar_events", "Jump to today")}
       ]},
      {dgettext("dashboard_calendar_events", "Views"),
       [
         {["1", "d"], dgettext("dashboard_calendar_events", "Day view")},
         {["2", "w"], dgettext("dashboard_calendar_events", "Week view")},
         {["3", "m"], dgettext("dashboard_calendar_events", "Month view")},
         {["4"], dgettext("dashboard_calendar_events", "Agenda view")}
       ]},
      {dgettext("dashboard_calendar_events", "Actions"),
       [
         {["c"], dgettext("dashboard_calendar_events", "Create event")},
         {["/"], dgettext("dashboard_calendar_events", "Focus search")},
         {["?"], dgettext("dashboard_calendar_events", "Toggle this help")},
         {["Esc"], dgettext("dashboard_calendar_events", "Close dialogs")}
       ]}
    ]
  end
end
