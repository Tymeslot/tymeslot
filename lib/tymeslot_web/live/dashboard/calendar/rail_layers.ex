defmodule TymeslotWeb.Dashboard.Calendar.RailLayers do
  @moduledoc """
  The rail's Layers section: the bookable-times layer's switch (B does the
  same from anywhere on the page) and the meeting type it shows. With no
  active meeting type there is nothing to show, so it offers to add one.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Components.UI.StatusSwitch

  attr :id_prefix, :string,
    default: "calendar-rail",
    doc: "keeps the rail's and the Calendars sheet's ids apart"

  attr :bookable, :map,
    required: true,
    doc: "`%{on, meeting_type, meeting_types}`, see `LayerChoices.rail/2`"

  attr :target, :any, required: true

  @spec layers(map()) :: Phoenix.LiveView.Rendered.t()
  def layers(assigns) do
    ~H"""
    <section id={"#{@id_prefix}-layers"} aria-labelledby={"#{@id_prefix}-layers-heading"}>
      <h2
        id={"#{@id_prefix}-layers-heading"}
        class="mb-2 text-token-xs font-semibold uppercase tracking-wide text-tymeslot-500"
      >
        {dgettext("dashboard_calendar_booking", "Layers")}
      </h2>
      <div :if={@bookable.meeting_types == []} class="space-y-1">
        <p class="text-token-sm text-tymeslot-500">
          {dgettext(
            "dashboard_calendar_booking",
            "No active meeting types, so there are no bookable times to show."
          )}
        </p>
        <.link
          navigate={~p"/dashboard/meeting-settings"}
          class="text-token-sm font-semibold text-turquoise-700 hover:text-turquoise-800"
        >
          {dgettext("dashboard_calendar_booking", "Add a meeting type")}
        </.link>
      </div>
      <div :if={@bookable.meeting_types != []} class="space-y-2">
        <div class="flex items-center gap-2">
          <span
            id={"#{@id_prefix}-bookable-label"}
            class="min-w-0 flex-1 text-token-sm font-semibold text-tymeslot-800"
          >
            {dgettext("dashboard_calendar_booking", "Bookable times")}
          </span>
          <StatusSwitch.status_switch
            id={"#{@id_prefix}-bookable"}
            checked={@bookable.on}
            size={:small}
            on_change="calendar:bookable_toggle"
            target={@target}
            phx-value-on={to_string(!@bookable.on)}
            aria-labelledby={"#{@id_prefix}-bookable-label"}
            aria-keyshortcuts="b"
          />
        </div>
        <form
          novalidate
          id={"#{@id_prefix}-bookable-form"}
          phx-change="calendar:bookable_type"
          phx-target={@target}
        >
          <.select
            id={"#{@id_prefix}-bookable-type"}
            name="meeting_type_id"
            label={dgettext("dashboard_calendar_booking", "Meeting type")}
            value={@bookable.meeting_type && @bookable.meeting_type.id}
            options={Enum.map(@bookable.meeting_types, &{&1.name, &1.id})}
          />
        </form>
        <p class="text-token-xs text-tymeslot-500">
          {dgettext(
            "dashboard_calendar_booking",
            "The hatched times are when guests can book this meeting type. Press B to hide them."
          )}
        </p>
      </div>
    </section>
    """
  end
end
