defmodule TymeslotWeb.Themes.Rhythm.Meeting.Reschedule do
  @moduledoc """
  Rhythm theme reschedule component with modern sliding style.
  """
  use Phoenix.Component

  import TymeslotWeb.Themes.Shared.Customization.Helpers

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  @doc """
  Renders the reschedule page in Rhythm theme style.
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
              <!-- Reschedule Container -->
              <div class="confirmation-container">
                <!-- Header with Icon -->
                <div class="confirmation-header-section">
                  <div class="success-badge">
                    <div
                      class="success-badge-inner"
                      style="background: linear-gradient(135deg, #6366f1 0%, #4f46e5 100%);"
                    >
                      <svg class="success-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                        />
                      </svg>
                    </div>
                  </div>

                  <h1 class="confirmation-headline">
                    Reschedule Appointment
                  </h1>

                  <p class="confirmation-message">
                    Select a new time for your meeting
                  </p>
                </div>
                
    <!-- Meeting Ticket Card -->
                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">Current Meeting Details</span>
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

                  <div class="ticket-footer">
                    <div class="email-confirmation">
                      <p style="text-align: center; color: var(--theme-text-secondary); margin: 0;">
                        Ready to pick a new time? Let's find one that works better for you.
                      </p>
                    </div>
                  </div>
                </div>
                
    <!-- Action Buttons -->
                <div
                  class="confirmation-actions"
                  style="display: flex; justify-content: center; margin-top: 2rem;"
                >
                  <button
                    phx-click={JS.navigate(get_base_url(assigns))}
                    class="action-button-primary"
                    type="button"
                    style="display: inline-flex; align-items: center; gap: 0.5rem;"
                  >
                    <span>Go to Calendar</span>
                    <svg
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                      style="width: 1.25rem; height: 1.25rem;"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                      >
                      </path>
                    </svg>
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Wrapper.rhythm_wrapper>
    """
  end

  defp get_base_url(assigns) do
    if assigns[:organizer_profile] && assigns.organizer_profile.username do
      "/#{assigns.organizer_profile.username}"
    else
      "/"
    end
  end
end
