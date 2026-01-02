defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Rhythm theme component for the confirmation/thank you step.
  Features clean, modern design with focus on readability.
  """
  use TymeslotWeb, :live_component

  @impl true
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl true
  def handle_event("schedule_another", _params, socket) do
    send(self(), {:step_event, :confirmation, :schedule_another, nil})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <!-- Scheduling Box with Glass Effect -->
      <div class="scheduling-box">
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content confirmation-slide">
              <!-- New Vertical Celebration Layout -->
              <div class="confirmation-container">
                <!-- Success Header with Animation -->
                <div class="confirmation-header-section">
                  <div class="success-badge">
                    <div class="success-badge-inner">
                      <svg class="success-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="3"
                          d="M5 13l4 4L19 7"
                        />
                      </svg>
                    </div>
                  </div>

                  <h1 class="confirmation-headline">
                    <%= if @is_rescheduling do %>
                      Successfully Rescheduled!
                    <% else %>
                      You're All Set!
                    <% end %>
                  </h1>

                  <p class="confirmation-message">
                    {@name}, your meeting{get_organizer_text(@organizer_profile)} is confirmed
                  </p>
                </div>
                
    <!-- Meeting Ticket Card -->
                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">Meeting Details</span>
                    <span class="ticket-badge">{@duration} min</span>
                  </div>

                  <div class="ticket-body">
                    <div class="ticket-row">
                      <div class="ticket-icon">📅</div>
                      <div class="ticket-info">
                        <span class="ticket-value">{format_date_display(@selected_date)}</span>
                        <span class="ticket-sublabel">Date</span>
                      </div>
                    </div>

                    <div class="ticket-row">
                      <div class="ticket-icon">🕐</div>
                      <div class="ticket-info">
                        <span class="ticket-value">{@selected_time}</span>
                        <span class="ticket-sublabel">{format_timezone_display(@user_timezone)}</span>
                      </div>
                    </div>

                    <%= if @organizer_profile do %>
                      <div class="ticket-row">
                        <div class="ticket-icon">👤</div>
                        <div class="ticket-info">
                          <span class="ticket-value">
                            {@organizer_profile.user.name || @organizer_profile.full_name}
                          </span>
                          <span class="ticket-sublabel">Meeting with</span>
                        </div>
                      </div>
                    <% end %>
                  </div>

                  <div class="ticket-footer">
                    <div class="email-confirmation">
                      <svg class="email-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 002 2z"
                        />
                      </svg>
                      <span>Sent to <strong>{@email}</strong></span>
                    </div>
                  </div>
                </div>
                
    <!-- Actions Section -->
                <div class="confirmation-actions-section">
                  <button
                    phx-click="schedule_another"
                    phx-target={@myself}
                    class="action-button-primary"
                  >
                    Schedule Another Meeting
                  </button>

                  <p class="help-text">
                    Need to make changes? Check your email for reschedule options
                  </p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Helper functions
  defp get_organizer_text(nil), do: ""

  defp get_organizer_text(organizer_profile) do
    " with #{organizer_profile.user.name || organizer_profile.full_name}"
  end

  defp format_date_display(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        "#{Calendar.strftime(date, "%B")} #{date.day}, #{date.year}"

      _ ->
        date_string
    end
  end

  defp format_timezone_display(timezone) do
    case String.split(timezone, "/") do
      [_continent, city | _rest] -> String.replace(city, "_", " ")
      _ -> timezone
    end
  end
end
