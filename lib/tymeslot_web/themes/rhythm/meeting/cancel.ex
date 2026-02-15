defmodule TymeslotWeb.Themes.Rhythm.Meeting.Cancel do
  @moduledoc """
  Rhythm theme cancel component with modern sliding style.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents

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
      custom_css={@custom_css}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
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
                    <div class="success-badge success-badge--transparent">
                      <div class="success-badge-inner success-badge-inner--success">
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
                      {gettext("Meeting Confirmed")}
                    </h1>

                    <p class="confirmation-message">
                      {gettext("Great! Your meeting is still scheduled as planned.")}
                    </p>
                  <% else %>
                    <div class="success-badge success-badge--transparent">
                      <div class="success-badge-inner success-badge-inner--danger">
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
                            d="M6 18L18 6M6 6l12 12"
                          />
                        </svg>
                      </div>
                    </div>

                    <h1 class="confirmation-headline">
                      {gettext("Cancel Appointment")}
                    </h1>

                    <p class="confirmation-message">
                      {gettext("Are you sure you want to cancel this appointment?")}
                    </p>
                  <% end %>
                </div>
                
    <!-- Meeting Ticket Card -->
                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">{gettext("Meeting Details")}</span>
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

                  <%= if assigns[:meeting_kept] do %>
                    <div class="ticket-footer">
                      <div class="email-confirmation">
                        <svg
                          class="email-icon email-icon--success"
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
                  <div class="confirmation-actions centered">
                    <button
                      phx-click={JS.navigate("/")}
                      class="action-button-primary action-button-success"
                      type="button"
                    >
                      Done
                    </button>
                  </div>
                <% else %>
                  <div class="confirmation-actions">
                    <button
                      phx-click="cancel_meeting"
                      class="action-button-primary action-button-danger"
                      type="button"
                      data-testid="cancel-meeting"
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
                      class="action-button-primary action-button-secondary"
                      type="button"
                      data-testid="keep-meeting"
                      disabled={@loading}
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
