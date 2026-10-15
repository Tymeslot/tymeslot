defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.ShowAsFreeSection do
  @moduledoc """
  Stateless function component for the meeting-type form's calendar
  availability toggle.

  Renders the "show as free" toggle. When enabled, bookings of this meeting
  type are written to the host's connected calendar as free/transparent
  (`TRANSP:TRANSPARENT` on CalDAV, `transparency=transparent` on Google,
  `showAs=free` on Outlook) so they do not block the host's availability. The
  toggle dispatches `toggle_show_as_free` back to the parent `MeetingTypeForm`
  (`@myself`), which owns the socket state and auto-save.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :show_as_free, :boolean, required: true
  attr :myself, :any, required: true

  @spec show_as_free_section(map()) :: Phoenix.LiveView.Rendered.t()
  def show_as_free_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.subsection_header
        icon="hero-calendar-days"
        title={dgettext("dashboard_meeting_form", "Calendar availability")}
      />

      <.setting_row
        id="show-as-free-toggle"
        label={dgettext("dashboard_meeting_form", "Show these bookings as free on my calendar")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "The event is still created, but marked as free time so it doesn't block other bookings or appear busy to people who can see your availability."
          )
        }
        checked={@show_as_free}
        on_change="toggle_show_as_free"
        target={@myself}
      />
    </section>
    """
  end
end
