defmodule TymeslotWeb.Dashboard.Calendar.ShortcutHelp do
  @moduledoc """
  The calendar's keyboard shortcuts: the help modal (`help/1`), opened
  as the `:shortcuts` surface menu by ?, by display options and by the
  command bar, and the screen-reader hints (`keys_hint/1`).

  `#calendar-keys-hint` is every event block's description, so it keeps to
  the keys that act on an event and points at the help; the whole map in
  prose is a second sr-only paragraph no event references. Key names are
  translated with a `key` context (German writes Strg and Entf); letters
  and digits are not.

  The modal is rendered only while open: the hook's `MODALS` selector
  matches its id, so an always-present element would silence every key.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :target, :any, required: true

  @spec help(map()) :: Phoenix.LiveView.Rendered.t()
  def help(assigns) do
    assigns = assign(assigns, :groups, groups())

    ~H"""
    <.modal
      id="calendar-shortcuts"
      show
      size={:medium}
      on_cancel={JS.push("calendar:close_menu", target: @target)}
    >
      <:header>{dgettext("dashboard_calendar", "Keyboard shortcuts")}</:header>
      <div class="grid gap-6 sm:grid-cols-2">
        <section :for={{title, rows} <- @groups}>
          <h3 class="mb-2 text-token-xs font-semibold uppercase tracking-wide text-tymeslot-500">
            {title}
          </h3>
          <dl class="space-y-1.5">
            <div :for={{keys, label} <- rows} class="flex items-center justify-between gap-3">
              <dt class="min-w-0 text-token-sm text-tymeslot-700">{label}</dt>
              <dd class="flex shrink-0 items-center gap-1">
                <%= for {key, index} <- Enum.with_index(keys) do %>
                  <span :if={index > 0} class="text-token-xs text-tymeslot-500" aria-hidden="true">+</span>
                  <kbd class="cal-kbd">{key}</kbd>
                <% end %>
              </dd>
            </div>
          </dl>
        </section>
      </div>
    </.modal>
    """
  end

  @spec keys_hint(map()) :: Phoenix.LiveView.Rendered.t()
  def keys_hint(assigns) do
    ~H"""
    <p id="calendar-keys-hint" class="sr-only">
      {dgettext(
        "dashboard_calendar",
        "Arrow keys move between events. Press C to add an event at the next free time. Press Enter to open the focused event, E to edit it, and M to move it: arrow keys then shift it, Shift with the arrow keys changes its length, Enter confirms and Escape cancels. Press Delete to delete the event and Ctrl Z (Cmd Z on a Mac) to undo."
      )}
      {dgettext("dashboard_calendar_booking", "Press B to show or hide your bookable times.")}
      {dgettext("dashboard_calendar_power", "Press ? to see every keyboard shortcut.")}
    </p>
    <p id="calendar-shortcuts-hint" class="sr-only">
      {dgettext(
        "dashboard_calendar_power",
        "Press T for today, J and K for the next and previous period, and D, X, W, M or A to change the view. Press 1 to 9 to apply a calendar set and 0 to leave it, F for focus mode on a wide screen, Ctrl K (Cmd K on a Mac) or / to search and run commands, and ? to see every shortcut."
      )}
    </p>
    """
  end

  defp groups do
    [
      {dgettext("dashboard_calendar_power", "Navigate"),
       [
         {["T"], dgettext("dashboard_calendar", "Today")},
         {["J"], dgettext("dashboard_calendar", "Next period")},
         {["K"], dgettext("dashboard_calendar", "Previous period")},
         {["D"], dgettext("dashboard_calendar", "Day")},
         {["X"], dgettext("dashboard_calendar", "3 days")},
         {["W"], dgettext("dashboard_calendar", "Week")},
         {["M"], dgettext("dashboard_calendar", "Month")},
         {["A"], dgettext("dashboard_calendar", "Agenda")},
         {[dpgettext("dashboard_calendar_power", "key", "Arrow keys")],
          dgettext("dashboard_calendar_power", "Move between events")}
       ]},
      {dgettext("dashboard_calendar_power", "Create and change"),
       [
         {["C"], dgettext("dashboard_calendar_power", "New event at the next free time")},
         {[dpgettext("dashboard_calendar_power", "key", "Enter")],
          dgettext("dashboard_calendar_power", "Open the focused event")},
         {["E"], dgettext("dashboard_calendar_power", "Edit the focused event")},
         {["M"], dgettext("dashboard_calendar_power", "Move the focused event")},
         {[dpgettext("dashboard_calendar_power", "key", "Arrow keys")],
          dgettext("dashboard_calendar_power", "While moving: shift the event")},
         {[
            dpgettext("dashboard_calendar_power", "key", "Shift"),
            dpgettext("dashboard_calendar_power", "key", "Arrow keys")
          ], dgettext("dashboard_calendar_power", "While moving: change its length")},
         {[dpgettext("dashboard_calendar_power", "key", "Enter")],
          dgettext("dashboard_calendar_power", "While moving: confirm")},
         {[dpgettext("dashboard_calendar_power", "key", "Esc")],
          dgettext("dashboard_calendar_power", "While moving: cancel")},
         {[dpgettext("dashboard_calendar_power", "key", "Delete")],
          dgettext("dashboard_calendar_power", "Delete the focused event")},
         {[dpgettext("dashboard_calendar_power", "key", "Ctrl"), "Z"],
          dgettext("dashboard_calendar_power", "Undo (Cmd Z on a Mac)")}
       ]},
      {dgettext("dashboard_calendar", "Calendars"),
       [
         {["1–9"], dgettext("dashboard_calendar_power", "Apply calendar set 1 to 9")},
         {["0"], dgettext("dashboard_calendar_power", "Leave the calendar set")},
         {["B"], dgettext("dashboard_calendar_power", "Show or hide bookable times")}
       ]},
      {dgettext("dashboard_calendar_power", "Anywhere"),
       [
         {[dpgettext("dashboard_calendar_power", "key", "Ctrl"), "K"],
          dgettext("dashboard_calendar_power", "Search and commands (Cmd K on a Mac)")},
         {["/"], dgettext("dashboard_calendar_power", "Search and commands")},
         {["F"], dgettext("dashboard_calendar_power", "Focus mode, on a wide screen")},
         {["?"], dgettext("dashboard_calendar", "Keyboard shortcuts")},
         {[dpgettext("dashboard_calendar_power", "key", "Esc")],
          dgettext("dashboard_calendar", "Close")}
       ]}
    ]
  end
end
