defmodule TymeslotWeb.Themes.Shared.Components.MeetingDetails do
  @moduledoc """
  Shared meeting detail rows used by cancel/reschedule pages across themes.
  Renders date, time, and organizer rows with icons. Themes wrap this in
  their own visual container (glassmorphism card, ticket, etc.) and provide
  CSS for the meeting-detail-* classes to match their visual style.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  attr :date, :string, required: true
  attr :time, :string, required: true
  attr :timezone, :string, default: nil
  attr :organizer_name, :string, default: nil
  attr :class, :string, default: nil

  @spec meeting_detail_rows(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_detail_rows(assigns) do
    ~H"""
    <div class={["meeting-detail-rows", @class]}>
      <div class="meeting-detail-row">
        <div class="meeting-detail-icon-wrapper">
          <.icon name="hero-calendar" class="meeting-detail-icon" />
        </div>
        <div class="meeting-detail-info">
          <span class="meeting-detail-value">{@date}</span>
          <span class="meeting-detail-label">{gettext("Date")}</span>
        </div>
      </div>
      <div class="meeting-detail-row">
        <div class="meeting-detail-icon-wrapper">
          <.icon name="hero-clock" class="meeting-detail-icon" />
        </div>
        <div class="meeting-detail-info">
          <span class="meeting-detail-value">{@time}</span>
          <%= if @timezone do %>
            <span class="meeting-detail-label">{@timezone}</span>
          <% end %>
        </div>
      </div>
      <%= if @organizer_name do %>
        <div class="meeting-detail-row meeting-detail-row--organizer">
          <div class="meeting-detail-icon-wrapper">
            <.icon name="hero-user" class="meeting-detail-icon" />
          </div>
          <div class="meeting-detail-info">
            <span class="meeting-detail-label">{gettext("Meeting with")}</span>
            <span class="meeting-detail-value">{@organizer_name}</span>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
