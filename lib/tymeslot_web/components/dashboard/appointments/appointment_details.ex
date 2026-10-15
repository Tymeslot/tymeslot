defmodule TymeslotWeb.Components.Dashboard.Appointments.AppointmentDetails do
  @moduledoc """
  The body and actions of an appointment's detail modal, shared by the
  overview's agenda modal and the calendar's booking modal so both describe an
  `Agenda.Entry` the same way: where it came from, how soon it is, when, how
  long, the video call, the place, who with and which calendar holds it, then
  Manage (for a Tymeslot booking) and Join (when there is a call).
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb, :verified_routes

  alias Tymeslot.Agenda.Entry
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.CoreComponents.Containers
  alias TymeslotWeb.Components.CoreComponents.Feedback
  alias TymeslotWeb.Components.Dashboard.Appointments.JoinLink
  alias TymeslotWeb.Dashboard.DashboardFormat
  alias TymeslotWeb.Dashboard.DashboardOverview.SourcePill
  alias TymeslotWeb.Dashboard.DashboardOverviewFormatters

  # Known video hosts and their friendly names. Self-hosted or unrecognised
  # links still read clearly as a video meeting via the fallback.
  @video_platforms [
    {"zoom.us", "Zoom"},
    {"meet.google.com", "Google Meet"},
    {"teams.microsoft.com", "Microsoft Teams"},
    {"teams.live.com", "Microsoft Teams"},
    {"whereby.com", "Whereby"},
    {"jit.si", "Jitsi Meet"}
  ]

  attr :entry, Entry, required: true
  attr :timezone, :string, required: true
  attr :time_format, :string, required: true
  attr :now, DateTime, required: true, doc: "Anchors the countdown pill"

  @spec appointment_details(map()) :: Phoenix.LiveView.Rendered.t()
  def appointment_details(assigns) do
    assigns =
      assign(assigns,
        relative: relative_label(assigns.entry, assigns.now),
        duration: duration_label(assigns.entry),
        place: location_place(assigns.entry)
      )

    ~H"""
    <div class="space-y-6">
      <div class="flex flex-wrap items-center gap-2">
        <SourcePill.source_pill source={@entry.source} />
        <Feedback.pill :if={@relative} tone={:brand} icon="hero-clock-mini">
          {@relative}
        </Feedback.pill>
      </div>

      <div class="space-y-4">
        <Containers.detail_line
          icon="hero-calendar-days"
          label={dgettext("dashboard_common", "When")}
        >
          {DashboardFormat.date_label(@entry, @timezone)}
        </Containers.detail_line>
        <Containers.detail_line icon="hero-clock" label={dgettext("dashboard_common", "Time")}>
          {DashboardFormat.entry_time_range(@entry, @timezone, @time_format)}
          <span :if={@duration} class="text-tymeslot-400 font-semibold">· {@duration}</span>
        </Containers.detail_line>
        <Containers.detail_line
          :if={@entry.join_url}
          icon="hero-video-camera"
          label={dgettext("dashboard_common", "Video meeting")}
        >
          {platform_label(@entry.join_url)}
        </Containers.detail_line>
        <Containers.detail_line
          :if={@place}
          icon="hero-map-pin"
          label={dgettext("dashboard_common", "Location")}
        >
          {@place}
        </Containers.detail_line>
        <Containers.detail_line
          :if={@entry.who || @entry.who_email}
          icon="hero-user"
          label={dgettext("dashboard_common", "With")}
        >
          <span :if={@entry.who} class="block">{@entry.who}</span>
          <a
            :if={@entry.who_email}
            href={"mailto:#{@entry.who_email}"}
            class="block text-token-sm font-semibold text-tymeslot-500 hover:text-turquoise-600 truncate"
          >
            {@entry.who_email}
          </a>
        </Containers.detail_line>
        <Containers.detail_line
          icon="hero-calendar"
          label={dgettext("dashboard_common", "Calendar")}
        >
          {calendar_label(@entry)}
        </Containers.detail_line>
      </div>
    </div>
    """
  end

  @doc "Whether `entry` offers any action for `appointment_actions/1` to show."
  @spec actions?(Entry.t()) :: boolean()
  def actions?(%Entry{} = entry), do: entry.source == :tymeslot or entry.join_url != nil

  attr :entry, Entry, required: true

  @spec appointment_actions(map()) :: Phoenix.LiveView.Rendered.t()
  def appointment_actions(assigns) do
    ~H"""
    <div class="flex flex-wrap justify-end gap-3">
      <Buttons.action_link
        :if={@entry.source == :tymeslot}
        patch={~p"/dashboard/meetings"}
        variant={:secondary}
        icon="hero-cog-6-tooth"
      >
        {dgettext("dashboard_common", "Manage booking")}
      </Buttons.action_link>
      <JoinLink.join_link :if={@entry.join_url} url={@entry.join_url} />
    </div>
    """
  end

  # A live hint anchored to the caller's `now`: counting down before it starts,
  # "In progress" while it runs, and nothing once it has ended.
  defp relative_label(%Entry{start_at: start_at, end_at: end_at}, now) do
    cond do
      DateTime.compare(now, end_at) != :lt -> nil
      DateTime.compare(now, start_at) != :lt -> dgettext("dashboard_common", "In progress")
      true -> DashboardOverviewFormatters.countdown(DateTime.diff(start_at, now, :second))
    end
  end

  defp duration_label(%Entry{all_day?: true}), do: nil

  defp duration_label(%Entry{} = entry),
    do: DashboardFormat.duration(entry.start_at, entry.end_at)

  defp platform_label(url) do
    host = URI.parse(url).host || ""

    Enum.find_value(@video_platforms, dgettext("dashboard_common", "Video call"), fn {needle,
                                                                                      name} ->
      String.contains?(host, needle) && name
    end)
  end

  # A physical place, if any: never the video link masquerading as a location.
  defp location_place(%Entry{location: nil}), do: nil

  defp location_place(%Entry{location: location}) do
    if String.starts_with?(location, ["http://", "https://"]), do: nil, else: location
  end

  # Where the appointment lives: a Tymeslot booking, or the named synced calendar.
  defp calendar_label(%Entry{source: :tymeslot}),
    do: dgettext("dashboard_common", "Booked through your Tymeslot page")

  defp calendar_label(%Entry{calendar: nil}),
    do: dgettext("dashboard_common", "External calendar")

  defp calendar_label(%Entry{calendar: name}), do: name
end
