defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.VisibilitySection do
  @moduledoc """
  Stateless function component for the meeting-type form's Visibility section.

  Renders the "hide from public booking page" switch for an existing meeting
  type (edit mode only — a type must exist before it can be hidden). Unlike
  the other sections, the toggle dispatches `toggle_private` to the parent
  `ServiceSettingsComponent` (`@parent`), which owns persistence of the flag
  and refreshes the meeting type list.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :type, :map, required: true
  attr :parent, :any, required: true

  @spec visibility_section(map()) :: Phoenix.LiveView.Rendered.t()
  def visibility_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.subsection_header
        icon="hero-eye-slash"
        title={dgettext("dashboard_meeting_form", "Visibility")}
      />

      <.setting_row
        id={"meeting-type-private-toggle-#{@type.id}"}
        control={:switch}
        label={dgettext("dashboard_meeting_form", "Hide from public booking page")}
        description={
          dgettext(
            "dashboard_meeting_form",
            "When on, this meeting type is reachable only through its direct link."
          )
        }
        checked={@type.is_private == true}
        on_change="toggle_private"
        target={@parent}
        phx-value-id={@type.id}
      />
    </section>
    """
  end
end
