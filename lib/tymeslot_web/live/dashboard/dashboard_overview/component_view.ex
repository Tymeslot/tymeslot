defmodule TymeslotWeb.Dashboard.DashboardOverview.ComponentView do
  @moduledoc """
  Markup for the dashboard overview: the onboarding checklist, the focus
  cockpit for the next appointment, and the day spine beneath it.

  Extracted from `DashboardOverviewComponent` so that module is left with the
  agenda view model and the events that rebuild it, matching how
  `CalendarSettings.ComponentView` sits behind `CalendarSettingsComponent`.
  `agenda/1` receives the component's assigns unchanged, so LiveView change
  tracking is preserved.

  The private function components here are the rail's vocabulary (cockpit,
  spine row, rail) and are only ever rendered from `agenda/1`; the rows
  themselves are `AppointmentRow`s.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Agenda.Day
  alias Tymeslot.Agenda.Entry
  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Components.Dashboard.Appointments.AppointmentRow
  alias TymeslotWeb.Components.Dashboard.Appointments.JoinLink
  alias TymeslotWeb.Dashboard.AgendaDetailModal
  alias TymeslotWeb.Dashboard.AgendaTimeline
  alias TymeslotWeb.Dashboard.DashboardFormat
  alias TymeslotWeb.Dashboard.OnboardingChecklist

  @spec agenda(map()) :: Phoenix.LiveView.Rendered.t()
  def agenda(assigns) do
    ~H"""
    <div class="space-y-10 pb-20">
      <.section_header icon="hero-home" title={dgettext("dashboard_home", "Overview")} />

      <%!-- Welcome Section --%>
      <div class="bg-linear-to-br from-turquoise-600 via-cyan-600 to-blue-600 rounded-token-3xl px-8 py-3 lg:px-12 lg:py-4 text-white shadow-2xl shadow-turquoise-500/20 relative overflow-hidden">
        <div class="absolute inset-0 bg-[radial-gradient(circle_at_30%_20%,rgba(255,255,255,0.15),transparent_50%)]">
        </div>
        <div class="relative z-10">
          <h1 class="text-3xl lg:text-4xl font-black mb-1 tracking-tight">
            {if @first_dashboard_visit,
              do: dgettext("dashboard_home", "Welcome"),
              else: dgettext("dashboard_home", "Welcome back")}{if @profile.full_name,
              do: ", #{@profile.full_name}",
              else: ""}!
          </h1>
          <p class="text-lg text-white/90 font-medium max-w-4xl leading-snug">
            {dgettext(
              "dashboard_home",
              "Here's an overview of your scheduling setup and recent activity."
            )}
          </p>
        </div>
      </div>

      <%!-- Onboarding checklist — only while setup is incomplete and not dismissed --%>
      <OnboardingChecklist.onboarding_checklist
        :if={OnboardingChecklist.visible?(@current_user, @integration_status)}
        integration_status={@integration_status}
        current_user={@current_user}
        profile={@profile}
      />

      <%!-- Live agenda --%>
      <div class="card-glass min-w-0">
        <div class="flex items-center justify-between gap-4 mb-8">
          <div class="flex items-center gap-3">
            <.section_header level={2} title={dgettext("dashboard_home", "Your day")} />
            <.pill :if={@today_count > 0} tone={:brand}>
              {@today_count} {dgettext("dashboard_home", "today")}
            </.pill>
          </div>
          <.link
            patch={~p"/dashboard"}
            class="text-turquoise-600 hover:text-turquoise-700 font-bold text-token-sm transition-colors flex items-center gap-1 group shrink-0"
          >
            {dgettext("dashboard_home", "View calendar")}
            <span class="group-hover:translate-x-1 transition-transform">→</span>
          </.link>
        </div>

        <%!-- Focus cockpit: the next appointment, zoomed in --%>
        <div :if={@agenda.next} class="mb-8">
          <.agenda_cockpit
            entry={@agenda.next}
            timezone={@agenda.timezone}
            time_format={@time_format}
            then_entry={@then_entry}
            more_count={@more_count}
            myself={@myself}
          />
        </div>

        <%!-- Today spine --%>
        <div :if={@spine != [] or @all_day_today != []} class="mb-8">
          <.group_heading label={dgettext("dashboard_home", "Today")} />

          <div :if={@all_day_today != []} class="mb-4 flex flex-wrap gap-2">
            <button
              :for={entry <- @all_day_today}
              type="button"
              {AppointmentRow.open_attrs("open_entry", %{"id" => entry.id}, target: @myself, keys: :none)}
              class="inline-flex items-center gap-1.5 rounded-token-full bg-tymeslot-100 px-3 py-1 text-token-xs font-black text-tymeslot-600 cursor-pointer hover:bg-tymeslot-200 focus:outline-hidden focus:ring-2 focus:ring-turquoise-400 transition-colors"
            >
              <span
                :if={EventColour.tailwind_class(entry.colour)}
                class={[
                  "w-2 h-2 rounded-token-full shrink-0",
                  EventColour.tailwind_class(entry.colour)
                ]}
                aria-hidden="true"
              ></span>
              <.icon
                :if={!EventColour.tailwind_class(entry.colour)}
                name="hero-sun-mini"
                class="w-4 h-4 text-tymeslot-400"
              />{entry.title}
            </button>
          </div>

          <div :if={@spine != []} class="relative">
            <.spine_row
              :for={row <- @spine}
              row={row}
              now={@now}
              timezone={@agenda.timezone}
              time_format={@time_format}
              myself={@myself}
            />
          </div>
        </div>

        <%!-- Tomorrow peek --%>
        <div :if={@tomorrow_entries != []} class="mt-8 pt-6 border-t border-tymeslot-100">
          <.group_heading label={dgettext("dashboard_home", "Tomorrow")} />
          <div class="space-y-2">
            <AppointmentRow.appointment_row
              :for={entry <- @tomorrow_entries}
              variant={:peek}
              entry={entry}
              on_open={open_attrs(entry, @myself)}
              timezone={@agenda.timezone}
              time_format={@time_format}
            />
          </div>
        </div>

        <%!-- Empty state --%>
        <.empty_state
          :if={Day.empty?(@agenda)}
          icon="hero-check-circle"
          variant={:dashed}
          title={dgettext("dashboard_home", "Nothing on your plate today or tomorrow")}
        />

        <%!-- Connect-a-calendar nudge --%>
        <.link
          :if={not @agenda.has_calendar?}
          navigate={~p"/dashboard/integrations?tab=calendars"}
          class="mt-2 flex items-center justify-center gap-2 text-token-sm font-bold text-turquoise-600 hover:text-turquoise-700 transition-colors"
        >
          <.icon name="hero-calendar-days" class="w-4 h-4" />
          {dgettext("dashboard_home", "Connect a calendar to see your whole schedule here")}
        </.link>
      </div>

      <%!-- Appointment detail modal --%>
      <AgendaDetailModal.agenda_detail_modal
        :if={@selected_entry}
        entry={@selected_entry}
        timezone={@agenda.timezone}
        time_format={@time_format}
        now={@now}
        myself={@myself}
      />
    </div>
    """
  end

  # Turns any agenda surface into a clickable, keyboard-focusable button that
  # opens the entry's detail modal.
  defp open_attrs(%Entry{id: id}, myself),
    do: AppointmentRow.open_attrs("open_entry", %{"id" => id}, target: myself)

  # --- Focus cockpit ---------------------------------------------------------

  attr :entry, :map, required: true
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :then_entry, :map, default: nil
  attr :more_count, :integer, default: 0
  attr :myself, :any, required: true

  defp agenda_cockpit(assigns) do
    ~H"""
    <div
      {open_attrs(@entry, @myself)}
      aria-label={dgettext("dashboard_common", "View details for %{title}", title: @entry.title)}
      class="relative overflow-hidden rounded-token-2xl bg-linear-to-br from-turquoise-600 via-cyan-600 to-blue-600 p-6 text-white shadow-xl shadow-turquoise-500/20 cursor-pointer focus:outline-hidden focus:ring-2 focus:ring-white/60"
    >
      <div class="absolute inset-0 bg-[radial-gradient(circle_at_20%_20%,rgba(255,255,255,0.15),transparent_55%)]">
      </div>
      <div class="relative z-10">
        <div class="flex items-center gap-2 text-token-xs font-black uppercase tracking-widest text-white/80">
          <.icon name="hero-bolt-mini" class="w-4 h-4" />
          <span>{dgettext("dashboard_home", "Up next")}</span>
          <span aria-hidden="true">·</span>
          <span>{DashboardFormat.day_label(@entry, @timezone)}</span>
        </div>

        <div class="mt-3 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0">
            <h3 class="text-token-2xl font-black tracking-tight truncate">{@entry.title}</h3>
            <p class="mt-1 text-white/90 font-semibold text-token-sm">
              {DashboardFormat.start_label(@entry, @timezone, @time_format)}<span :if={@entry.who}> · {@entry.who}</span>
            </p>
            <p
              :if={@entry.location}
              class="mt-1 flex items-center gap-1 text-white/75 text-token-xs font-semibold truncate"
            >
              <.icon name="hero-map-pin-mini" class="w-4 h-4 shrink-0" />{@entry.location}
            </p>
          </div>

          <div class="flex items-center gap-4 shrink-0">
            <JoinLink.agenda_countdown
              entry={@entry}
              id_prefix="agenda-cockpit"
              class="text-token-4xl"
            />
          </div>
        </div>

        <p
          :if={@then_entry}
          class="mt-4 pt-4 border-t border-white/20 text-white/80 text-token-xs font-semibold truncate"
        >
          <span class="uppercase tracking-widest text-white/60">{dgettext(
            "dashboard_home",
            "then"
          )}</span>
          {@then_entry.title} · {DashboardFormat.start_label(@then_entry, @timezone, @time_format)}
          <span :if={@more_count > 0}>
            · {dngettext(
              "dashboard_home",
              "+%{count} more",
              "+%{count} more",
              @more_count
            )}
          </span>
        </p>
      </div>
    </div>
    """
  end

  # --- Day spine -------------------------------------------------------------

  attr :row, :any, required: true
  attr :now, :map, required: true
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :myself, :any, required: true

  defp spine_row(%{row: {:event, _entry, _meta}} = assigns) do
    {:event, entry, meta} = assigns.row

    assigns =
      assign(assigns,
        entry: entry,
        highlight?: meta[:next?] or meta[:in_progress?],
        in_progress?: meta[:in_progress?],
        colour_class: EventColour.tailwind_class(entry.colour)
      )

    ~H"""
    <div class="flex gap-3">
      <div class="w-12 shrink-0 pt-3.5 text-right text-token-xs font-black tabular-nums text-tymeslot-400">
        {DashboardFormat.start_label(@entry, @timezone, @time_format)}
      </div>
      <.rail node={if @in_progress?, do: :live, else: :event} colour_class={@colour_class} />
      <AppointmentRow.appointment_row
        variant={:spine}
        entry={@entry}
        on_open={open_attrs(@entry, @myself)}
        timezone={@timezone}
        time_format={@time_format}
        colour_class={@colour_class}
        highlight={@highlight?}
        live={@in_progress?}
      />
    </div>
    """
  end

  defp spine_row(%{row: {:gap, minutes}} = assigns) do
    assigns = assign(assigns, :minutes, minutes)

    ~H"""
    <div class="flex gap-3">
      <div class="w-12 shrink-0"></div>
      <.rail node={:none} dashed />
      <div class="flex-1 py-2 text-token-xs font-bold text-tymeslot-400 flex items-center gap-1.5">
        <.icon name="hero-sparkles-mini" class="w-3.5 h-3.5 text-tymeslot-300" />
        {AgendaTimeline.format_gap(@minutes)}
      </div>
    </div>
    """
  end

  defp spine_row(%{row: :now} = assigns) do
    ~H"""
    <div class="flex gap-3">
      <div class="w-12 shrink-0 pt-1.5 text-right text-token-xs font-black tabular-nums text-turquoise-600">
        {DashboardFormat.clock(@now, @timezone, @time_format)}
      </div>
      <.rail node={:now} />
      <div class="flex-1 py-1 text-token-xs font-black uppercase tracking-widest text-turquoise-600">
        {dgettext("dashboard_home", "Now")}
      </div>
    </div>
    """
  end

  # The vertical rail column: a centred line with an optional node dot.
  attr :node, :atom, required: true
  attr :dashed, :boolean, default: false
  attr :colour_class, :string, default: nil

  defp rail(assigns) do
    ~H"""
    <div class="relative w-3 shrink-0 flex justify-center">
      <span class={[
        "absolute inset-y-0 border-l-2",
        @dashed && "border-dashed border-tymeslot-200",
        not @dashed && "border-tymeslot-100"
      ]}></span>
      <span
        :if={@node == :event}
        class={[
          "relative mt-4 w-3 h-3 rounded-token-full border-2",
          @colour_class && ["#{@colour_class}", "border-transparent"],
          !@colour_class && "bg-white border-tymeslot-300"
        ]}
      ></span>
      <span
        :if={@node == :live}
        class="relative mt-4 w-3 h-3 rounded-token-full bg-turquoise-500 ring-4 ring-turquoise-500/15 animate-pulse"
      ></span>
      <span
        :if={@node == :now}
        class="relative mt-1.5 w-3.5 h-3.5 rounded-token-full bg-turquoise-500 ring-4 ring-turquoise-500/20 animate-pulse"
      ></span>
    </div>
    """
  end

  # --- Shared bits -----------------------------------------------------------

  attr :label, :string, required: true

  defp group_heading(assigns) do
    ~H"""
    <h4 class="mb-3 text-token-xs font-black uppercase tracking-widest text-tymeslot-400">
      {@label}
    </h4>
    """
  end
end
