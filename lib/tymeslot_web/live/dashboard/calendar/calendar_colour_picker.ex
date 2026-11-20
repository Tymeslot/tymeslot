defmodule TymeslotWeb.Dashboard.Calendar.CalendarColourPicker do
  @moduledoc """
  A calendar's own colour in the rail and the Calendars sheet: a swatch
  button beside the calendar (`toggle/1`) opens the shared palette under
  it (`palette/1`, `ColourSwatches`), whose choice `CalendarColours` stores.
  "Default colour" gives the calendar its account's colour again.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.Dashboard.ColourSwatches

  attr :id, :string, required: true
  attr :account, :map, required: true
  attr :calendar, :map, required: true
  attr :open, :boolean, required: true
  attr :controls, :string, required: true, doc: "the palette's id"
  attr :target, :any, required: true

  @spec toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def toggle(assigns) do
    ~H"""
    <.icon_button
      id={@id}
      icon="hero-swatch-mini"
      size={:sm}
      label={dgettext("dashboard_calendar", "Colour of %{calendar}", calendar: @calendar.name)}
      aria-expanded={to_string(@open)}
      aria-controls={@controls}
      data-calendar-colour={@calendar.id}
      phx-click="calendar:calendar_colour_open"
      phx-value-integration-id={@account.id}
      phx-value-calendar-id={@calendar.id}
      phx-target={@target}
    />
    """
  end

  attr :id, :string, required: true
  attr :account, :map, required: true
  attr :calendar, :map, required: true
  attr :selected, :string, default: nil, doc: "the calendar's stored palette key, or nil"
  attr :target, :any, required: true

  @spec palette(map()) :: Phoenix.LiveView.Rendered.t()
  def palette(assigns) do
    ~H"""
    <div id={@id} class="basis-full py-1.5 pl-8">
      <ColourSwatches.colour_swatches
        selected={@selected}
        event="calendar:set_calendar_colour"
        target={@target}
        values={%{"phx-value-integration-id" => @account.id, "phx-value-calendar-id" => @calendar.id}}
        group_label={
          dgettext("dashboard_calendar", "Colour of %{calendar}", calendar: @calendar.name)
        }
      />
    </div>
    """
  end
end
