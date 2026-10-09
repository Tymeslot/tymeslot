defmodule TymeslotWeb.Components.Dashboard.Appointments.AppointmentRow do
  @moduledoc """
  One appointment (`Tymeslot.Agenda.Entry`) as a clickable row, in the shape
  each dashboard list needs:

    * `:spine`: a card on the overview's day rail, with who and where, a source
      pill, a "Now" badge while it runs and a Join link.
    * `:peek`: a single compact line in the overview's Tomorrow peek.
    * `:list`: a row of the calendar's agenda list, led by its time range.

  What a click opens is the caller's: `on_open` is the attribute map from
  `OpenAttrs.build/3`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Agenda.Entry
  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Components.CoreComponents.Feedback
  alias TymeslotWeb.Components.CoreComponents.Icons
  alias TymeslotWeb.Components.Dashboard.Appointments.JoinLink
  alias TymeslotWeb.Dashboard.DashboardFormat
  alias TymeslotWeb.Dashboard.DashboardOverview.SourcePill

  attr :entry, Entry, required: true
  attr :variant, :atom, required: true, values: [:spine, :peek, :list]
  attr :on_open, :map, required: true, doc: "From `OpenAttrs.build/3`"
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true

  attr :colour_class, :string,
    default: nil,
    doc: "The colour's Tailwind class, when the caller resolves it; else the entry's own"

  attr :highlight, :boolean, default: false, doc: "`:spine`: lift the card (next, or running)"
  attr :live, :boolean, default: false, doc: "`:spine`: badge the card as happening now"
  attr :rest, :global

  @spec appointment_row(map()) :: Phoenix.LiveView.Rendered.t()
  def appointment_row(assigns) do
    assigns
    |> assign(
      :colour_class,
      assigns.colour_class || EventColour.tailwind_class(assigns.entry.colour)
    )
    |> assign(:title, DashboardFormat.title(assigns.entry.title))
    |> render_row()
  end

  defp render_row(%{variant: :spine} = assigns) do
    ~H"""
    <div
      {@on_open}
      {@rest}
      aria-label={dgettext("dashboard_common", "View details for %{title}", title: @title)}
      class={[
        "flex-1 min-w-0 mb-3 flex items-center gap-3 p-4 rounded-token-2xl border-2 transition-all group cursor-pointer focus:outline-hidden focus:ring-2 focus:ring-turquoise-400",
        @highlight && "bg-white border-turquoise-200 shadow-md shadow-turquoise-500/10",
        not @highlight && "bg-tymeslot-50/50 border-tymeslot-50 hover:bg-white hover:shadow-md"
      ]}
    >
      <span
        :if={@colour_class}
        class={["w-1 self-stretch shrink-0 rounded-token-full", @colour_class]}
        aria-hidden="true"
      ></span>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-tymeslot-900 font-black tracking-tight truncate group-hover:text-turquoise-700 transition-colors">
            {@title}
          </span>
          <Feedback.pill :if={@live} tone={:brand} pulse uppercase>
            {dgettext("dashboard_common", "Now")}
          </Feedback.pill>
          <SourcePill.source_pill source={@entry.source} />
        </div>
        <div
          :if={@entry.who || @entry.location}
          class="mt-0.5 text-token-sm text-tymeslot-500 font-semibold truncate"
        >
          <span :if={@entry.who}>{@entry.who}</span>
          <span :if={@entry.who && @entry.location}> · </span>
          <span :if={@entry.location}>{@entry.location}</span>
        </div>
      </div>
      <JoinLink.join_link
        :if={@entry.join_url}
        url={@entry.join_url}
        variant={:secondary}
        size={:sm}
        class="shrink-0"
      />
    </div>
    """
  end

  defp render_row(%{variant: :peek} = assigns) do
    ~H"""
    <div
      {@on_open}
      {@rest}
      aria-label={dgettext("dashboard_common", "View details for %{title}", title: @title)}
      class="flex items-center gap-3 py-1.5 px-2 -mx-2 rounded-token-xl cursor-pointer hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400 transition-colors"
    >
      <div class="w-14 shrink-0 text-token-xs font-black tabular-nums text-tymeslot-400">
        {DashboardFormat.start_label(@entry, @timezone, @time_format)}
      </div>
      <span
        :if={@colour_class}
        class={["w-2 h-2 shrink-0 rounded-token-full", @colour_class]}
        aria-hidden="true"
      ></span>
      <span class="flex-1 min-w-0 text-token-sm text-tymeslot-700 font-bold truncate">
        {@title}
      </span>
      <span
        :if={@entry.who}
        class="shrink-0 text-token-xs text-tymeslot-400 font-semibold truncate max-w-[40%]"
      >
        {@entry.who}
      </span>
    </div>
    """
  end

  defp render_row(%{variant: :list} = assigns) do
    assigns =
      assign(
        assigns,
        :time,
        DashboardFormat.entry_time_range(assigns.entry, assigns.timezone, assigns.time_format)
      )

    ~H"""
    <li
      {@on_open}
      {@rest}
      aria-label={dgettext("dashboard_common", "%{event}, %{time}", event: @title, time: @time)}
      class="flex items-start gap-3 rounded-token-md px-2 py-2 cursor-pointer hover:bg-tymeslot-50 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400"
    >
      <span
        class={["mt-0.5 w-2.5 h-2.5 rounded-token-full shrink-0", @colour_class || "bg-tymeslot-300"]}
        aria-hidden="true"
      ></span>
      <span class="w-28 sm:w-36 shrink-0 text-token-xs text-tymeslot-500 tabular-nums pt-0.5">
        {@time}
      </span>
      <span class="min-w-0 flex-1">
        <span class="block text-token-sm font-medium text-tymeslot-800 truncate">{@title}</span>
        <span
          :if={@entry.location}
          class="mt-0.5 flex items-center gap-1 text-token-xs text-tymeslot-500"
        >
          <Icons.icon name="hero-map-pin-micro" class="w-3 h-3 shrink-0" />
          <span class="truncate">{@entry.location}</span>
        </span>
      </span>
    </li>
    """
  end
end
