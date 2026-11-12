defmodule TymeslotWeb.Dashboard.CalendarSettings.FeedControls do
  @moduledoc """
  The settings of a subscribed calendar, shown on its card: a subscription
  has no Manage calendars modal, so whether its one calendar blocks the
  booking page, and whether every event in the feed counts as busy, are
  chosen here. Every subscription gets the busy toggle; the blocking choice
  needs the feed's calendar entry, which a subscription without a calendar
  list lacks.

  On a feed set to Don't block the toggle has nothing to act on, so it is
  shown disabled, still pressed or not as stored, until the feed blocks
  again. A subscription with no blocking choice blocks as it always did, and
  its toggle stays live.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.CalendarSettings.Helpers

  @doc "The subscription's busy-time controls, for its card's footer."
  attr :integration, :map, required: true
  attr :feed, :map, default: nil
  attr :display_name, :string, required: true
  attr :myself, :any, required: true

  @spec feed_controls(map()) :: Phoenix.LiveView.Rendered.t()
  def feed_controls(assigns) do
    assigns = assign(assigns, :busy_inert?, match?(%{blocks_availability: false}, assigns.feed))

    ~H"""
    <.segmented_control
      :if={@feed}
      id={"calendar-#{@integration.id}-feed-busy"}
      size={:sm}
      value={to_string(@feed.blocks_availability)}
      aria_label={
        dgettext("dashboard_calendar_settings", "Busy times of %{calendar}", calendar: @display_name)
      }
      on_change={
        JS.push("set_calendar_blocking",
          value: %{integration_id: @integration.id, calendar_id: @feed.id},
          target: @myself
        )
      }
      param="blocks"
    >
      <:option value="true" label={dgettext("dashboard_calendar_settings", "Block")} />
      <:option value="false" label={dgettext("dashboard_calendar_settings", "Don't block")} />
    </.segmented_control>
    <%!-- Whether every event in the feed blocks time, also those it marks
         free (holiday feeds mark all of them free). --%>
    <.tooltip
      :let={tip}
      id={"all-events-busy-#{@integration.id}-tip"}
      text={
        if @busy_inert?,
          do:
            dgettext(
              "dashboard_calendar_settings",
              "Turn on Block to use this: a calendar that doesn't block busy times has nothing for it to change"
            ),
          else:
            dgettext(
              "dashboard_calendar_settings",
              "Block the time of every event in this feed, also those it marks as free"
            )
      }
    >
      <%!-- `aria-disabled` when inert, so it stays focusable to explain itself;
           `Calendar.set_all_events_busy/3` refuses the change either way. --%>
      <button
        type="button"
        phx-click={!@busy_inert? && "toggle_all_events_busy"}
        phx-value-id={@integration.id}
        phx-target={@myself}
        class={[Helpers.tile_class(:neutral), @busy_inert? && "opacity-50"]}
        aria-pressed={to_string(@integration.all_events_busy)}
        aria-disabled={@busy_inert? && "true"}
        aria-describedby={tip}
        data-testid="all-events-busy-toggle"
      >
        <.icon
          name={if @integration.all_events_busy, do: "hero-check-circle", else: "hero-no-symbol"}
          class="w-4 h-4"
        /><span>{dgettext("dashboard_calendar_settings", "Every event busy")}</span>
      </button>
    </.tooltip>
    """
  end
end
