defmodule TymeslotWeb.Themes.Shared.Components.CalendarRefusedNotice do
  @moduledoc """
  Tells the organiser, on their own booking page, that a calendar of theirs
  is flagged for reconnection, that visitors may see no times until it is
  reconnected, and where to reconnect it.

  A guest on the same page is told only that times cannot be shown
  (`BookingErrorMessage.message(:host_calendar_disconnected)`): the
  calendar's name stays with its owner. `LiveHelpers.Mount` assigns
  `:refused_calendars` to the names only when the viewer is the organiser,
  by their signed session or a verified preview token, and to `[]` for
  everyone else, so this renders nothing for a guest.

  Rendered by `Shared.Components.ThemeShell.chrome/1`, on every step, and
  drawn with the owner-preview notice's styles
  (`assets/css/scheduling/shared/components/preview-notice.css`): both are
  warnings to the organiser that sit on the page background.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  @reconnect_path "/dashboard/integrations?tab=calendars"

  attr :names, :list, default: [], doc: "the refused calendars' names; `[]` renders nothing"

  @doc "Renders nothing unless `names` lists a refused calendar."
  @spec notice(map()) :: Phoenix.LiveView.Rendered.t()
  def notice(assigns) do
    assigns = assign(assigns, :reconnect_path, @reconnect_path)

    ~H"""
    <div
      :if={@names != []}
      class="preview-notice calendar-refused-notice"
      role="alert"
      data-testid="calendar-refused-notice"
    >
      <.icon name="hero-exclamation-triangle" class="preview-notice-icon" />
      <span class="preview-notice-text">
        {dngettext(
          "booking",
          "Your calendar %{names} needs reconnecting. Until you do, visitors may see no times here.",
          "Your calendars %{names} need reconnecting. Until you do, visitors may see no times here.",
          length(@names),
          names: Enum.join(@names, ", ")
        )}
        <a
          href={@reconnect_path}
          target="_blank"
          rel="noopener"
          class="preview-notice-link"
          data-testid="calendar-refused-reconnect"
        >
          {dgettext("booking", "Reconnect")}
        </a>
      </span>
    </div>
    """
  end
end
