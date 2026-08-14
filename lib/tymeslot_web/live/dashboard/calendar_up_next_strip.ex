defmodule TymeslotWeb.Dashboard.CalendarUpNextStrip do
  @moduledoc """
  Slim "Up next" strip rendered above the calendar grid.

  A compact cousin of the overview's focus cockpit: the next appointment's
  title, time and counterpart, a live countdown, and a Join button that the
  `AgendaCountdown` hook reveals as the start approaches.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Dashboard.DashboardOverviewFormatters, as: Formatters

  attr :entry, :map, required: true
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true

  @spec up_next_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def up_next_strip(assigns) do
    ~H"""
    <div
      class="mx-3 md:mx-4 mt-2 flex items-center gap-3 rounded-token-xl bg-linear-to-r from-turquoise-600 to-cyan-600 px-4 py-2.5 text-white shadow-lg shadow-turquoise-500/20 shrink-0"
      data-testid="up-next-strip"
    >
      <div class="flex items-center gap-1.5 text-token-xs font-black uppercase tracking-widest text-white/80 shrink-0">
        <.icon name="hero-bolt-mini" class="w-4 h-4" />
        <span class="hidden sm:inline">{dgettext("dashboard_home", "Up next")}</span>
      </div>
      <div class="min-w-0 flex-1 truncate text-token-sm font-semibold">
        {@entry.title}
        <span class="text-white/80 font-medium">
          · {Formatters.day_label(@entry, @timezone)} · {Formatters.time_label(
            @entry,
            @timezone,
            @time_format
          )}<span :if={@entry.who}> · {@entry.who}</span>
        </span>
      </div>
      <%!-- Key the id on the start time too: `phx-update="ignore"` hands the
            element to the JS hook, so a same-id reschedule would otherwise
            count toward the old time. A changed start → new id → remount. --%>
      <time
        id={"calendar-up-next-countdown-#{@entry.id}-#{DateTime.to_unix(@entry.start_at)}"}
        phx-hook="AgendaCountdown"
        phx-update="ignore"
        data-start={DateTime.to_iso8601(@entry.start_at)}
        data-end={DateTime.to_iso8601(@entry.end_at)}
        data-join={@entry.join_url && "calendar-up-next-join-#{@entry.id}"}
        class="text-token-lg font-black tabular-nums leading-none shrink-0"
      >{Formatters.relative_hint(@entry)}</time>
      <a
        :if={@entry.join_url}
        id={"calendar-up-next-join-#{@entry.id}"}
        href={@entry.join_url}
        target="_blank"
        rel="noopener noreferrer"
        class="hidden shrink-0 items-center gap-1.5 rounded-token-lg bg-white px-3 py-1.5 text-token-sm font-black text-turquoise-700 shadow-lg hover:bg-turquoise-50 transition-colors"
      >
        <.icon name="hero-video-camera-mini" class="w-4 h-4" />
        {dgettext("dashboard_home", "Join")}
      </a>
    </div>
    """
  end
end
