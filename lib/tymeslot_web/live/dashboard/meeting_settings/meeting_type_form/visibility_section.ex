defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.VisibilitySection do
  @moduledoc """
  Stateless function component for the meeting-type form's Visibility section.

  Renders one "Show on …" switch per page for a meeting type: the profile's
  own page at `/<username>` dispatches `toggle_private`, a booking page
  `toggle_page_membership`, both to the parent `ServiceSettingsComponent`
  (`@parent`), which owns persistence.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :type, :map, default: nil
  attr :parent, :any, required: true
  attr :pages, :list, default: [], doc: "`PageVisibility.rows/4`, the username's page first"

  @spec visibility_section(map()) :: Phoenix.LiveView.Rendered.t()
  def visibility_section(assigns) do
    ~H"""
    <section :if={@pages != []} class="space-y-4">
      <.subsection_header
        icon="hero-eye-slash"
        title={dgettext("dashboard_meeting_form", "Visibility")}
      />

      <.setting_row
        :for={page <- @pages}
        id={toggle_id(@type, page)}
        control={:switch}
        label={dgettext("dashboard_meeting_form", "Show on %{address}", address: "/" <> page.address)}
        checked={page.checked}
        on_change={toggle_event(page)}
        target={@parent}
        phx-value-id={@type.id}
        phx-value-page={page.id}
      />

      <p
        :if={Enum.all?(@pages, &(not &1.checked))}
        class="text-token-sm text-tymeslot-500"
        data-testid="unlisted-note"
      >
        {dgettext(
          "dashboard_meeting_form",
          "On no booking page: bookable only through its direct link."
        )}
      </p>
    </section>
    """
  end

  # The username's page keeps the control id and event it always had.
  defp toggle_id(type, %{id: "profile"}), do: "meeting-type-private-toggle-#{type.id}"
  defp toggle_id(type, page), do: "meeting-type-page-toggle-#{type.id}-#{page.id}"

  defp toggle_event(%{id: "profile"}), do: "toggle_private"
  defp toggle_event(_page), do: "toggle_page_membership"
end
