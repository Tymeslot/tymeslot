defmodule TymeslotWeb.Dashboard.CalendarGrid.VideoPicker do
  @moduledoc """
  The row of buttons an organiser picks an event's video provider from.

  One component for every place the grid offers the choice — the new-event
  modal, the ad-hoc meeting form and the event detail modal — so the pressed
  state, the "None" button and the provider icons cannot drift apart between
  creating an event and editing one. Each caller supplies the event name its
  own handler listens for.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Icons.ProviderIcon

  attr :video_integrations, :list, required: true
  attr :selected_id, :any, default: nil
  attr :target, :any, required: true
  attr :phx_event, :string, required: true

  @spec video_picker(map()) :: Phoenix.LiveView.Rendered.t()
  def video_picker(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-1.5">
      <button
        type="button"
        phx-click={@phx_event}
        phx-value-video_integration_id=""
        phx-target={@target}
        class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if is_nil(@selected_id), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
      >
        {dgettext("dashboard_calendar_events", "None")}
      </button>
      <button
        :for={vi <- @video_integrations}
        type="button"
        phx-click={@phx_event}
        phx-value-video_integration_id={vi.id}
        phx-target={@target}
        class={"inline-flex items-center gap-1.5 px-2.5 py-1 rounded-lg border text-token-xs transition-all #{if to_string(vi.id) == to_string(@selected_id), do: "border-turquoise-400 bg-turquoise-50 text-turquoise-800 shadow-sm font-semibold", else: "border-tymeslot-200 text-tymeslot-600 hover:border-tymeslot-300 hover:bg-tymeslot-50"}"}
      >
        <ProviderIcon.provider_icon provider={vi.provider} type="video" size="mini" />
        <span class="truncate max-w-[10rem]">{vi.name}</span>
      </button>
    </div>
    """
  end
end
