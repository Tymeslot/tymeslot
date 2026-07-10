defmodule TymeslotWeb.Dashboard.AgendaDetailModal do
  @moduledoc """
  Detail modal for a single agenda appointment.

  Stateless function component rendered by `DashboardOverviewComponent` when a
  row in the agenda is clicked. It presents everything the source-agnostic
  `Agenda.Entry` carries — full date, time range and duration, who, location,
  source, and a live relative hint — plus the two smart actions the entry can
  offer: a Join button for video events and a "Manage booking" link for Tymeslot
  bookings. Dismissal dispatches `close_entry` back to the owning component
  (`@myself`), which holds the open/closed state.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Agenda.Entry
  alias Tymeslot.Integrations.Calendar.EventColour
  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Helpers.LocaleFormat

  attr :entry, Entry, required: true
  attr :timezone, :string, required: true
  attr :now, DateTime, required: true
  attr :myself, :any, required: true

  @spec agenda_detail_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def agenda_detail_modal(assigns) do
    ~H"""
    <.modal
      id="agenda-detail-modal"
      show={true}
      on_cancel={JS.push("close_entry", target: @myself)}
      size={:medium}
    >
      <:header>{@entry.title}</:header>

      <div class="space-y-6">
        <div class="flex flex-wrap items-center gap-2">
          <.source_badge source={@entry.source} />
          <span
            :if={relative_label(@entry, @now)}
            class="inline-flex items-center gap-1 rounded-token-full bg-turquoise-50 px-2.5 py-0.5 text-token-xs font-black text-turquoise-700"
          >
            <.icon name="hero-clock-mini" class="w-3.5 h-3.5" />{relative_label(@entry, @now)}
          </span>
        </div>

        <dl class="space-y-4">
          <.info_line icon="hero-calendar-days" label={dgettext("dashboard_home", "When")}>
            {date_label(@entry, @timezone)}
          </.info_line>
          <.info_line icon="hero-clock" label={dgettext("dashboard_home", "Time")}>
            {time_label(@entry, @timezone)}<span :if={duration_label(@entry)} class="text-tymeslot-400 font-semibold">
              · {duration_label(@entry)}</span>
          </.info_line>
          <.info_line
            :if={@entry.join_url}
            icon="hero-video-camera"
            label={dgettext("dashboard_home", "Video meeting")}
          >
            {platform_label(@entry.join_url)}
          </.info_line>
          <.info_line
            :if={location_place(@entry)}
            icon="hero-map-pin"
            label={dgettext("dashboard_home", "Location")}
          >
            {location_place(@entry)}
          </.info_line>
          <.info_line :if={@entry.who} icon="hero-user" label={dgettext("dashboard_home", "With")}>
            {@entry.who}
          </.info_line>
          <.info_line icon="hero-calendar" label={dgettext("dashboard_home", "Calendar")}>
            {calendar_label(@entry)}
          </.info_line>
        </dl>

        <div :if={@entry.target}>
          <p id="agenda-colour-picker-label" class="text-token-xs font-black uppercase tracking-widest text-tymeslot-400 mb-2">
            {dgettext("dashboard_home", "Colour")}
          </p>
          <div
            role="radiogroup"
            aria-labelledby="agenda-colour-picker-label"
            class="flex flex-wrap items-center gap-2"
          >
            <button
              :for={{key, label, swatch_class} <- EventColour.palette()}
              type="button"
              role="radio"
              aria-checked={@entry.colour == key}
              phx-click="set_entry_colour"
              phx-value-colour={key}
              phx-value-target={encode_target(@entry.target)}
              phx-target={@myself}
              aria-label={label}
              class={[
                "w-7 h-7 rounded-token-full border-2 transition",
                swatch_class,
                @entry.colour == key && "ring-2 ring-turquoise-500 ring-offset-2 border-white",
                @entry.colour != key && "border-transparent hover:scale-110"
              ]}
            >
            </button>
            <button
              type="button"
              role="radio"
              aria-checked={@entry.colour == nil}
              phx-click="clear_entry_colour"
              phx-value-target={encode_target(@entry.target)}
              phx-target={@myself}
              class={[
                "inline-flex items-center h-7 px-3 rounded-token-full border text-token-xs font-bold transition",
                @entry.colour == nil && "border-turquoise-400 text-turquoise-700 bg-turquoise-50",
                @entry.colour != nil && "border-tymeslot-200 text-tymeslot-500 hover:bg-tymeslot-50"
              ]}
            >
              {dgettext("dashboard_home", "Default")}
            </button>
          </div>
        </div>
      </div>

      <:footer :if={@entry.join_url || @entry.source == :tymeslot}>
        <div class="flex flex-wrap justify-end gap-3">
          <.link
            :if={@entry.source == :tymeslot}
            navigate={~p"/dashboard/meetings"}
            class="action-button action-button--secondary"
          >
            <.icon name="hero-cog-6-tooth-mini" class="w-4 h-4" /> {dgettext(
              "dashboard_home",
              "Manage booking"
            )}
          </.link>
          <a
            :if={@entry.join_url}
            href={@entry.join_url}
            target="_blank"
            rel="noopener noreferrer"
            class="action-button action-button--primary"
          >
            <.icon name="hero-video-camera-mini" class="w-4 h-4" /> {dgettext(
              "dashboard_home",
              "Join"
            )}
          </a>
        </div>
      </:footer>
    </.modal>
    """
  end

  # Encodes an entry's colour target into a DOM-safe string for `phx-value-*`.
  # `DashboardOverviewComponent.decode_target/1` is the inverse. `parts: 2` keeps
  # any colons inside a provider uid intact on the way back.
  defp encode_target({:meeting, id}), do: "meeting:#{id}"
  defp encode_target({:external, integration_id, uid}), do: "external:#{integration_id}:#{uid}"

  # --- Info rows -------------------------------------------------------------

  attr :icon, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp info_line(assigns) do
    ~H"""
    <div class="flex items-start gap-3">
      <.icon name={@icon} class="w-5 h-5 text-turquoise-500 shrink-0 mt-0.5" />
      <div class="min-w-0">
        <dt class="text-token-xs font-black uppercase tracking-widest text-tymeslot-400">
          {@label}
        </dt>
        <dd class="mt-0.5 text-tymeslot-800 font-bold break-words">{render_slot(@inner_block)}</dd>
      </div>
    </div>
    """
  end

  attr :source, :atom, required: true

  defp source_badge(%{source: :tymeslot} = assigns) do
    ~H"""
    <span class="rounded-token-full bg-turquoise-100 px-2.5 py-0.5 text-token-xs font-black uppercase tracking-wider text-turquoise-700">
      {dgettext("dashboard_home", "Booking")}
    </span>
    """
  end

  defp source_badge(assigns) do
    ~H"""
    <span class="rounded-token-full bg-tymeslot-100 px-2.5 py-0.5 text-token-xs font-black uppercase tracking-wider text-tymeslot-600">
      {dgettext("dashboard_home", "Calendar")}
    </span>
    """
  end

  # --- Video, location & calendar --------------------------------------------

  # Known video hosts → a friendly platform name. Self-hosted or unrecognised
  # links still read clearly as a video meeting via the fallback.
  @video_platforms [
    {"zoom.us", "Zoom"},
    {"meet.google.com", "Google Meet"},
    {"teams.microsoft.com", "Microsoft Teams"},
    {"teams.live.com", "Microsoft Teams"},
    {"whereby.com", "Whereby"},
    {"jit.si", "Jitsi Meet"}
  ]

  defp platform_label(url) do
    host = URI.parse(url).host || ""

    Enum.find_value(@video_platforms, dgettext("dashboard_home", "Video call"), fn {needle, name} ->
      String.contains?(host, needle) && name
    end)
  end

  # A physical place, if any — never the video link masquerading as a location.
  defp location_place(%Entry{location: nil}), do: nil

  defp location_place(%Entry{location: location}) do
    if String.starts_with?(location, ["http://", "https://"]), do: nil, else: location
  end

  # Where the appointment lives: a Tymeslot booking, or the named synced calendar.
  defp calendar_label(%Entry{source: :tymeslot}), do: "Tymeslot"
  defp calendar_label(%Entry{calendar: nil}), do: dgettext("dashboard_home", "External calendar")
  defp calendar_label(%Entry{calendar: name}), do: name

  # --- Formatting ------------------------------------------------------------

  # An all-day block spans [start_day, end_day]; its `end_at` is the exclusive
  # local midnight after the final day, so the last covered day is end_at - 1.
  defp date_label(%Entry{all_day?: true} = entry, tz) do
    first = local_date(entry.start_at, tz)
    last = entry.end_at |> local_date(tz) |> Date.add(-1)

    case Date.compare(first, last) do
      :lt -> "#{long_date(first)} – #{long_date(last)}"
      _same -> long_date(first)
    end
  end

  defp date_label(%Entry{} = entry, tz), do: entry.start_at |> local(tz) |> long_date()

  defp time_label(%Entry{all_day?: true}, _tz), do: dgettext("dashboard_home", "All day")

  defp time_label(%Entry{} = entry, tz) do
    "#{clock(entry.start_at, tz)} – #{clock(entry.end_at, tz)}"
  end

  defp duration_label(%Entry{all_day?: true}), do: nil

  defp duration_label(%Entry{start_at: start_at, end_at: end_at}) do
    case max(DateTime.diff(end_at, start_at, :minute), 0) do
      0 -> nil
      minutes -> humanise_duration(minutes)
    end
  end

  defp humanise_duration(minutes) when minutes < 60,
    do: dgettext("dashboard_home", "%{minutes} min", minutes: minutes)

  defp humanise_duration(minutes) do
    case {div(minutes, 60), rem(minutes, 60)} do
      {hours, 0} ->
        dgettext("dashboard_home", "%{hours} hr", hours: hours)

      {hours, mins} ->
        dgettext("dashboard_home", "%{hours} hr %{mins} min", hours: hours, mins: mins)
    end
  end

  # A live hint anchored to the caller's `now`: counting down before it starts,
  # "In progress" while it runs, and nothing once it has ended.
  defp relative_label(%Entry{start_at: start_at, end_at: end_at}, now) do
    cond do
      DateTime.compare(now, end_at) != :lt -> nil
      DateTime.compare(now, start_at) != :lt -> dgettext("dashboard_home", "In progress")
      true -> countdown(DateTime.diff(start_at, now, :second))
    end
  end

  defp countdown(seconds) when seconds < 3600,
    do: dgettext("dashboard_home", "in %{minutes}m", minutes: max(div(seconds, 60), 1))

  defp countdown(seconds) when seconds < 86_400,
    do: dgettext("dashboard_home", "in %{hours}h", hours: div(seconds, 3600))

  defp countdown(seconds),
    do: dgettext("dashboard_home", "in %{days}d", days: div(seconds, 86_400))

  defp clock(datetime, tz) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    datetime |> local(tz) |> LocaleFormat.format_time(locale)
  end

  defp long_date(date) do
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    weekday = LocaleFormat.format_weekday_name(Date.day_of_week(date), locale, :full)
    month = LocaleFormat.format_month_name(date.month, locale, :full)
    "#{weekday}, #{date.day} #{month} #{date.year}"
  end

  defp local(datetime, tz), do: DateTimeUtils.convert_to_timezone(datetime, tz)

  defp local_date(datetime, tz), do: datetime |> local(tz) |> DateTime.to_date()
end
