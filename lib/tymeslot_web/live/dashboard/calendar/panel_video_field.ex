defmodule TymeslotWeb.Dashboard.Calendar.PanelVideoField do
  @moduledoc """
  The side panel's Video row. In the edit mode (`video_row/1`): Join and
  "Remove link" for an event with a call; "Add video call" (a button for
  the only integration, a select for several) for one without; a note for
  the calendar copy of a booking or an organiser with no video integration.
  In the new-event mode (`video_choice/1`): a select, one field of the draft.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :event, :map, required: true
  attr :video_integrations, :list, required: true
  attr :booking_copy, :boolean, required: true
  attr :saving, :boolean, required: true
  attr :surface, :any, required: true
  attr :editable, :boolean, default: true
  attr :version, :integer, default: 0, doc: "a new version draws the select again"

  @spec video_row(map()) :: Phoenix.LiveView.Rendered.t()
  def video_row(assigns) do
    assigns =
      assign(assigns,
        link: web_url(Map.get(assigns.event, :video_link) || Map.get(assigns.event, :join_url)),
        creating:
          assigns.saving and is_integer(Map.get(assigns.event, :video_integration_id)) and
            is_nil(Map.get(assigns.event, :video_link))
      )

    ~H"""
    <section :if={@editable or @link} id="calendar-panel-video" class="space-y-2">
      <h3 class="label mb-0">
        {dgettext("dashboard_calendar_editing", "Video call")}
      </h3>
      <p :if={@booking_copy} class="text-token-sm text-tymeslot-500">
        {dgettext("dashboard_calendar_editing", "The video call belongs to the booking.")}
      </p>
      <div :if={@link} class="flex flex-wrap items-center gap-2">
        <.link
          id="calendar-panel-join"
          href={@link}
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center gap-1.5 rounded-token-lg bg-turquoise-700 px-3 py-1.5 text-token-sm font-semibold text-white hover:bg-turquoise-800 focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-turquoise-400"
        >
          <.icon name="hero-video-camera-mini" class="h-4 w-4" />
          {dgettext("dashboard_calendar_editing", "Join")}
        </.link>
        <.action_button
          :if={@editable and !@booking_copy}
          id="calendar-panel-video-remove"
          variant={:secondary}
          size={:sm}
          phx-click="panel:video"
          phx-value-video_integration_id=""
          phx-target={@surface}
        >
          {dgettext("dashboard_calendar_editing", "Remove link")}
        </.action_button>
      </div>
      <p :if={@editable && !@booking_copy && @creating} class="text-token-sm text-tymeslot-500">
        {dgettext("dashboard_calendar_editing", "Creating the video call…")}
      </p>
      <div :if={@editable && !@booking_copy && !@link && !@creating}>
        <p :if={@video_integrations == []} class="text-token-sm text-tymeslot-500">
          {dgettext("dashboard_calendar_editing", "No video integration connected.")}
        </p>
        <.action_button
          :if={match?([_only], @video_integrations)}
          id="calendar-panel-video-add"
          variant={:secondary}
          size={:sm}
          icon="hero-video-camera"
          phx-click="panel:video"
          phx-value-video_integration_id={hd(@video_integrations).id}
          phx-target={@surface}
        >
          {dgettext("dashboard_calendar_editing", "Add video call")}
        </.action_button>
        <form
          :if={match?([_first, _second | _rest], @video_integrations)}
          novalidate
          id="calendar-panel-video-form"
          phx-change="panel:video"
          phx-target={@surface}
        >
          <div id={"calendar-panel-video-field-#{@version}"}>
            <.select
              id="calendar-panel-video-choice"
              name="video_integration_id"
              label={dgettext("dashboard_calendar_editing", "Add video call")}
              prompt={dgettext("dashboard_calendar_editing", "Choose a provider")}
              options={for vi <- @video_integrations, do: {vi.name, vi.id}}
              value=""
            />
          </div>
        </form>
      </div>
    </section>
    """
  end

  attr :video_integrations, :list, required: true
  attr :value, :any, default: nil

  @spec video_choice(map()) :: Phoenix.LiveView.Rendered.t()
  def video_choice(assigns) do
    ~H"""
    <.select
      :if={@video_integrations != []}
      id="calendar-panel-new-video"
      name="video_integration_id"
      label={dgettext("dashboard_calendar_editing", "Video call")}
      prompt={dgettext("dashboard_calendar_editing", "No video call")}
      options={for vi <- @video_integrations, do: {vi.name, vi.id}}
      value={@value}
    />
    """
  end

  defp web_url(url) when is_binary(url) do
    trimmed = String.trim(url)
    if URI.parse(trimmed).scheme in ["https", "http"], do: trimmed
  end

  defp web_url(_url), do: nil
end
