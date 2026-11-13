defmodule TymeslotWeb.Dashboard.Calendar.PowerOverlays do
  @moduledoc """
  What the power layer lays over the calendar surface, rendered by one call
  in `CalendarSurface.render/1`, after the toast: the desktop-notification
  feed's hook element (Task 6), then the import modal (Task 8), the
  shortcut help (Task 12) and the command bar (Task 14). Everything here
  sits outside `#calendar-canvas`, which LiveView never patches.
  """

  use TymeslotWeb, :html

  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias TymeslotWeb.Dashboard.Calendar.CommandBar
  alias TymeslotWeb.Dashboard.Calendar.ImportModal
  alias TymeslotWeb.Dashboard.Calendar.ShortcutHelp

  attr :reminders_enabled, :boolean, required: true
  attr :reminder_feed, :list, required: true
  attr :ics_import, :map, default: nil
  attr :uploads, :map, required: true
  attr :accounts, :list, required: true
  attr :open_menu, :atom, default: nil
  attr :command, :map, required: true
  attr :target, :any, required: true

  @spec overlays(map()) :: Phoenix.LiveView.Rendered.t()
  def overlays(assigns) do
    ~H"""
    <%!-- The DesktopReminders hook reads the feed from its data attributes and
          fires notifications on its own timer (see `ReminderFeed`). --%>
    <div
      id="calendar-reminder-feed"
      phx-hook="DesktopReminders"
      data-enabled={to_string(@reminders_enabled)}
      data-reminders={Jason.encode!(@reminder_feed)}
      hidden
    >
    </div>
    <ImportModal.import_modal
      :if={@ics_import && @ics_import.open}
      ics_import={@ics_import}
      uploads={@uploads}
      choices={CalendarDirectory.choices(@accounts)}
      target={@target}
    />
    <ShortcutHelp.help :if={@open_menu == :shortcuts} target={@target} />
    <CommandBar.command_bar command={@command} target={@target} />
    """
  end
end
