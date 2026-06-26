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

  attr :show_as_free, :boolean, required: true
  attr :myself, :any, required: true

  @spec show_as_free_section(map()) :: Phoenix.LiveView.Rendered.t()
  def show_as_free_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <div class="flex items-center gap-2">
        <.icon name="hero-calendar-days" class="w-5 h-5 text-turquoise-500" />
        <h3 class="text-token-base font-semibold text-tymeslot-800">Calendar availability</h3>
      </div>

      <label class="card-glass flex items-start gap-3 p-4 cursor-pointer">
        <input
          type="checkbox"
          class="checkbox mt-0.5"
          checked={@show_as_free}
          phx-click="toggle_show_as_free"
          phx-target={@myself}
        />
        <div class="space-y-1">
          <p class="text-token-sm font-medium text-tymeslot-700">
            Show these bookings as free on my calendar
          </p>
          <p class="text-token-sm text-tymeslot-500">
            The event is still created, but marked as free time so it doesn't block
            other bookings or appear busy to people who can see your availability.
          </p>
        </div>
      </label>
    </section>
    """
  end
end
