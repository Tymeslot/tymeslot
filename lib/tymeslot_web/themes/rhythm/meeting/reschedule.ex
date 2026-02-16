defmodule TymeslotWeb.Themes.Rhythm.Meeting.Reschedule do
  @moduledoc """
  Rhythm theme reschedule component with modern sliding style.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  attr :theme_customization, :map, required: true
  attr :custom_css, :string, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true
  attr :meeting, :map, required: true
  attr :organizer_profile, :map, default: nil

  @doc """
  Renders the reschedule page in Rhythm theme style.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.rhythm_wrapper
      theme_customization={@theme_customization}
      custom_css={@custom_css}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
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
                    <div class="success-badge-inner success-badge-inner--info">
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
                    {gettext("Reschedule Appointment")}
                  </h1>

                  <p class="confirmation-message">
                    {gettext("Select a new time for your meeting")}
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
                      <div class="ticket-icon">
                        <.icon name="hero-calendar" class="hero-icon hero-icon--md" />
                      </div>
                      <div class="ticket-info">
                        <span class="ticket-value">
                          {Calendar.strftime(@meeting.start_time, "%B %d, %Y")}
                        </span>
                        <span class="ticket-sublabel">Date</span>
                      </div>
                    </div>

                    <div class="ticket-row">
                      <div class="ticket-icon">
                        <.icon name="hero-clock" class="hero-icon hero-icon--md" />
                      </div>
                      <div class="ticket-info">
                        <span class="ticket-value">
                          {Calendar.strftime(@meeting.start_time, "%I:%M %p")}
                        </span>
                        <span class="ticket-sublabel">{@meeting.attendee_timezone}</span>
                      </div>
                    </div>

                    <div class="ticket-row">
                      <div class="ticket-icon">
                        <.icon name="hero-user" class="hero-icon hero-icon--md" />
                      </div>
                      <div class="ticket-info">
                        <span class="ticket-sublabel">Meeting with</span>
                        <span class="ticket-value">{@meeting.organizer_name}</span>
                      </div>
                    </div>
                  </div>

                  <div class="ticket-footer">
                    <div class="email-confirmation">
                      <p class="ticket-footer-message">
                        Ready to pick a new time? Let's find one that works better for you.
                      </p>
                    </div>
                  </div>
                </div>
                
    <!-- Action Buttons -->
                <div class="confirmation-actions centered">
                  <button
                    phx-click={JS.navigate(get_base_url(assigns))}
                    class="action-button-primary"
                    type="button"
                  >
                    <span>Go to Calendar</span>
                    <svg
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                      class="icon-sm"
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
