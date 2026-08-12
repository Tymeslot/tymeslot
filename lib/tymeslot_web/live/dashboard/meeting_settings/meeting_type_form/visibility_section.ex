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
      <div class="flex items-center gap-2">
        <.icon name="hero-eye-slash" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-800">
          {dgettext("dashboard_meeting_form", "Visibility")}
        </h3>
      </div>

      <div class="card-glass flex items-center justify-between gap-4 p-4">
        <div class="space-y-1">
          <p class="text-token-sm font-medium text-tymeslot-700">
            {dgettext("dashboard_meeting_form", "Hide from public booking page")}
          </p>
          <p class="text-token-sm text-tymeslot-500">
            {dgettext(
              "dashboard_meeting_form",
              "When on, this meeting type is reachable only through its direct link."
            )}
          </p>
        </div>
        <button
          type="button"
          phx-click="toggle_private"
          phx-value-id={@type.id}
          phx-target={@parent}
          role="switch"
          aria-checked={@type.is_private}
          aria-label={dgettext("dashboard_meeting_form", "Hide from public booking page")}
          class={[
            "relative inline-flex h-5 w-9 shrink-0 cursor-pointer rounded-full border-2 transition-colors duration-200 ease-in-out focus:outline-hidden focus:ring-2 focus:ring-turquoise-500 focus:ring-offset-2",
            if(@type.is_private,
              do: "bg-turquoise-500 border-turquoise-500",
              else: "bg-tymeslot-300 border-tymeslot-300"
            )
          ]}
        >
          <span class={[
            "pointer-events-none inline-block h-4 w-4 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
            if(@type.is_private, do: "translate-x-4", else: "translate-x-0")
          ]} />
        </button>
      </div>
    </section>
    """
  end
end
