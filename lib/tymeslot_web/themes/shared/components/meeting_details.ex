defmodule TymeslotWeb.Themes.Shared.Components.MeetingDetails do
  @moduledoc """
  Shared meeting detail rows used by cancel/reschedule pages across themes.
  Renders date, time, and organizer rows with icons. Themes wrap this in
  their own visual container (glassmorphism card, ticket, etc.) and provide
  CSS for the meeting-detail-* classes to match their visual style.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  attr :start_time, :any, required: true, doc: "the meeting's stored UTC DateTime"
  attr :timezone, :string, default: nil, doc: "the attendee's zone; nil falls back"
  attr :organizer_profile, :map, default: nil, doc: "fallback zone when the attendee's is unknown"
  attr :locale, :string, required: true
  attr :organizer_name, :string, default: nil
  attr :class, :string, default: nil

  @spec meeting_detail_rows(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_detail_rows(assigns) do
    assigns = assign_local_time(assigns)

    ~H"""
    <div class={["meeting-detail-rows", @class]}>
      <div class="meeting-detail-row">
        <div class="meeting-detail-icon-wrapper">
          <.icon name="hero-calendar" class="meeting-detail-icon" />
        </div>
        <div class="meeting-detail-info">
          <span class="meeting-detail-value">{@date}</span>
          <span class="meeting-detail-label">{dgettext("booking", "Date")}</span>
        </div>
      </div>
      <div class="meeting-detail-row">
        <div class="meeting-detail-icon-wrapper">
          <.icon name="hero-clock" class="meeting-detail-icon" />
        </div>
        <div class="meeting-detail-info">
          <span class="meeting-detail-value">{@time}</span>
          <%= if @zone_label do %>
            <span class="meeting-detail-label">{@zone_label}</span>
          <% end %>
        </div>
      </div>
      <%= if @organizer_name do %>
        <div class="meeting-detail-row meeting-detail-row--organizer">
          <div class="meeting-detail-icon-wrapper">
            <.icon name="hero-user" class="meeting-detail-icon" />
          </div>
          <div class="meeting-detail-info">
            <span class="meeting-detail-label">{dgettext("booking", "Meeting with")}</span>
            <span class="meeting-detail-value">{@organizer_name}</span>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # An attendee booked in their own zone, so that is what the meeting should be
  # shown in. Older and ad-hoc meetings carry no attendee zone, in which case the
  # organiser's is a closer guess than UTC. Both may be absent.
  defp display_zone(timezone, _profile) when is_binary(timezone) and timezone != "", do: timezone
  defp display_zone(_timezone, %{timezone: tz}) when is_binary(tz) and tz != "", do: tz
  defp display_zone(_timezone, _profile), do: nil

  # The zone label is taken from the shifted struct rather than from the
  # requested timezone, so it always describes the clock actually rendered.
  defp assign_local_time(assigns) do
    zone = display_zone(assigns.timezone, assigns.organizer_profile)

    case LocalizationHelpers.to_attendee_datetime(assigns.start_time, zone) do
      {:ok, dt} ->
        assign(assigns,
          date: LocaleFormat.format_date(dt, assigns.locale),
          time: LocaleFormat.format_time(dt, assigns.locale),
          zone_label: dt.time_zone
        )

      :error ->
        assign(assigns, date: "", time: "", zone_label: nil)
    end
  end
end
