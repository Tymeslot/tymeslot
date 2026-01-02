defmodule TymeslotWeb.Themes.Rhythm.Meeting.Cancel do
  @moduledoc """
  Rhythm theme cancel component with modern sliding style.
  """
  use Phoenix.Component

  import TymeslotWeb.Themes.Shared.Customization.Helpers

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  @doc """
  Renders the cancel page in Rhythm theme style.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.rhythm_wrapper
      theme_customization={@theme_customization}
      custom_css={generate_custom_css(@theme_customization)}
    >
      <!-- Scheduling Box with Glass Effect -->
      <div class="scheduling-box">
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content confirmation-slide">
              <!-- Cancel Container -->
              <div class="confirmation-container">
                <!-- Header with Icon -->
                <div class="confirmation-header-section">
                  <%= if assigns[:meeting_kept] do %>
                    <div
                      class="success-badge"
                      style="background: linear-gradient(135deg, #10b981 0%, #059669 100%);"
                    >
                      <div class="success-badge-inner">
                        <svg
                          class="success-icon"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                          />
                        </svg>
                      </div>
                    </div>

                    <h1 class="confirmation-headline">
                      Meeting Confirmed
                    </h1>

                    <p class="confirmation-message">
                      Great! Your meeting is still scheduled as planned.
                    </p>
                  <% else %>
                    <div class="success-badge" style="background: transparent;">
                      <div class="success-badge-inner">
                        <svg
                          class="success-icon"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                          style="color: #ef4444;"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M6 18L18 6M6 6l12 12"
                          />
                        </svg>
                      </div>
                    </div>

                    <h1 class="confirmation-headline">
                      Cancel Appointment
                    </h1>

                    <p class="confirmation-message">
                      Are you sure you want to cancel this appointment?
                    </p>
                  <% end %>
                </div>
                
    <!-- Meeting Ticket Card -->
                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">Meeting Details</span>
                    <span class="ticket-badge">{@meeting.duration} min</span>
                  </div>

                  <div class="ticket-body">
                    <div class="ticket-row">
                      <div class="ticket-icon">📅</div>
                      <div class="ticket-info">
                        <span class="ticket-value">
                          {Calendar.strftime(@meeting.start_time, "%B %d, %Y")}
                        </span>
                        <span class="ticket-sublabel">Date</span>
                      </div>
                    </div>

                    <div class="ticket-row">
                      <div class="ticket-icon">🕐</div>
                      <div class="ticket-info">
                        <span class="ticket-value">
                          {Calendar.strftime(@meeting.start_time, "%I:%M %p")}
                        </span>
                        <span class="ticket-sublabel">{@meeting.attendee_timezone}</span>
                      </div>
                    </div>

                    <div class="ticket-row">
                      <div class="ticket-icon">👤</div>
                      <div class="ticket-info">
                        <span class="ticket-sublabel">Meeting with</span>
                        <span class="ticket-value">{@meeting.organizer_name}</span>
                      </div>
                    </div>
                  </div>

                  <%= if assigns[:meeting_kept] do %>
                    <div class="ticket-footer">
                      <div class="email-confirmation">
                        <svg
                          class="email-icon"
                          fill="none"
                          stroke="currentColor"
                          viewBox="0 0 24 24"
                          style="color: #10b981;"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                          />
                        </svg>
                        <span>We look forward to seeing you at the scheduled time.</span>
                      </div>
                    </div>
                  <% else %>
                    <div class="ticket-footer">
                      <div class="email-confirmation">
                        <svg class="email-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                          />
                        </svg>
                        <span>A cancellation email will be sent to all participants</span>
                      </div>
                    </div>
                  <% end %>
                </div>
                
    <!-- Action Buttons -->
                <%= if assigns[:meeting_kept] do %>
                  <div class="confirmation-actions" style="display: flex; justify-content: center;">
                    <button
                      phx-click={JS.navigate("/")}
                      class="action-button-primary"
                      type="button"
                      style="background: linear-gradient(135deg, #10b981 0%, #059669 100%); display: inline-flex; align-items: center; gap: 0.5rem;"
                    >
                      Done
                    </button>
                  </div>
                <% else %>
                  <div class="confirmation-actions" style="display: flex; gap: 1rem;">
                    <button
                      phx-click="cancel_meeting"
                      class="action-button-primary"
                      type="button"
                      style="background: linear-gradient(135deg, #ef4444 0%, #dc2626 100%); display: inline-flex; align-items: center; gap: 0.5rem;"
                      disabled={@loading}
                    >
                      <%= if @loading do %>
                        Cancelling...
                      <% else %>
                        Yes, Cancel Meeting
                      <% end %>
                    </button>

                    <button
                      phx-click="keep_meeting"
                      class="action-button-primary"
                      type="button"
                      style="background: rgba(255, 255, 255, 0.1); backdrop-filter: blur(10px); display: inline-flex; align-items: center; gap: 0.5rem;"
                    >
                      Keep Meeting
                    </button>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Wrapper.rhythm_wrapper>
    """
  end
end
