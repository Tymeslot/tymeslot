defmodule TymeslotWeb.Themes.Rhythm.Shared.MeetingTicket do
  @moduledoc """
  Shared meeting ticket card component for the Rhythm theme.
  Displays meeting details in a card format with date, time, and optional organizer info.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

  @doc """
  Renders a meeting details ticket card.

  ## Attributes
  - header_label: Header text (e.g., "Meeting Details", "Current Meeting Details")
  - duration_minutes: Meeting duration in minutes
  - date_value: Formatted date string
  - time_value: Formatted time string
  - timezone_label: Timezone display string
  - organizer_name: Optional organizer name to display
  - show_organizer: Whether to show the organizer row
  - footer_content: Optional slot for footer content
  """
  attr :header_label, :string, required: true
  attr :duration_minutes, :integer, required: true
  attr :date_value, :string, required: true
  attr :time_value, :string, required: true
  attr :timezone_label, :string, required: true
  attr :organizer_name, :string, default: nil
  attr :show_organizer, :boolean, default: false

  slot :footer

  @spec meeting_ticket(map()) :: Phoenix.LiveView.Rendered.t()
  def meeting_ticket(assigns) do
    ~H"""
    <div class="meeting-ticket">
      <div class="ticket-header">
        <span class="ticket-label">{@header_label}</span>
        <span class="ticket-badge">{@duration_minutes} min</span>
      </div>

      <div class="ticket-body">
        <div class="ticket-row">
          <div class="ticket-icon">
            <.icon name="hero-calendar" class="hero-icon hero-icon--md" />
          </div>
          <div class="ticket-info">
            <span class="ticket-value">{@date_value}</span>
            <span class="ticket-sublabel">{dgettext("booking", "Date")}</span>
          </div>
        </div>

        <div class="ticket-row">
          <div class="ticket-icon">
            <.icon name="hero-clock" class="hero-icon hero-icon--md" />
          </div>
          <div class="ticket-info">
            <span class="ticket-value">{@time_value}</span>
            <span class="ticket-sublabel">{@timezone_label}</span>
          </div>
        </div>

        <%= if @show_organizer && @organizer_name do %>
          <div class="ticket-row">
            <div class="ticket-icon">
              <.icon name="hero-user" class="hero-icon hero-icon--md" />
            </div>
            <div class="ticket-info">
              <span class="ticket-value">{@organizer_name}</span>
              <span class="ticket-sublabel">{dgettext("booking", "Meeting with")}</span>
            </div>
          </div>
        <% end %>
      </div>

      <%= if @footer != [] do %>
        <div class="ticket-footer">
          <%= render_slot(@footer) %>
        </div>
      <% end %>
    </div>
    """
  end
end
