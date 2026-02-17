defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Rhythm theme component for the confirmation/thank you step.
  Features clean, modern design with focus on readability.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  import TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("schedule_another", _params, socket) do
    send(self(), {:step_event, :confirmation, :schedule_another, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div data-locale={@locale}>
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

                  <h1 class="confirmation-headline" data-testid="confirmation-heading">
                    <%= if @is_rescheduling do %>
                      {gettext("Successfully Rescheduled!")}
                    <% else %>
                      {gettext("You're All Set!")}
                    <% end %>
                  </h1>

                  <p class="confirmation-message">
                    {gettext("%{name}, your meeting %{organizer} is confirmed", name: @name, organizer: get_organizer_text(@organizer_profile))}
                  </p>
                </div>
                
    <!-- Meeting Ticket Card -->
                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">{gettext("Meeting Details")}</span>
                    <span class="ticket-badge">
                      <%= if @meeting_type, do: @meeting_type.duration_minutes, else: @duration %> min
                    </span>
                  </div>

                  <div class="ticket-body">
                    <div class="ticket-row">
                      <div class="ticket-icon">
                        <.icon name="hero-calendar" class="hero-icon hero-icon--md" />
                      </div>
                      <div class="ticket-info">
                        <span class="ticket-value">{LocalizationHelpers.format_date(@selected_date)}</span>
                        <span class="ticket-sublabel">{gettext("Date")}</span>
                      </div>
                    </div>

                    <div class="ticket-row">
                      <div class="ticket-icon">
                        <.icon name="hero-clock" class="hero-icon hero-icon--md" />
                      </div>
                      <div class="ticket-info">
                        <span class="ticket-value">{@selected_time}</span>
                        <span class="ticket-sublabel">{format_timezone_display(@user_timezone)}</span>
                      </div>
                    </div>

                    <%= if @organizer_profile do %>
                      <div class="ticket-row">
                        <div class="ticket-icon">
                          <.icon name="hero-user" class="hero-icon hero-icon--md" />
                        </div>
                        <div class="ticket-info">
                          <span class="ticket-value">
                            {@organizer_profile.user.name || @organizer_profile.full_name}
                          </span>
                          <span class="ticket-sublabel">{gettext("Meeting with")}</span>
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
                      <span>{gettext("Sent to")} <strong>{@email}</strong></span>
                    </div>
                  </div>
                </div>
                
    <!-- Actions Section -->
                <div class="confirmation-actions-section">
                  <button
                    phx-click="schedule_another"
                    phx-target={@myself}
                    data-testid="schedule-another"
                    class="action-button-primary"
                  >
                    {gettext("Schedule Another Meeting")}
                  </button>

                  <p class="help-text">
                    {gettext("Need to make changes? Check your email for reschedule options")}
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
    gettext("with %{name}", name: organizer_profile.user.name || organizer_profile.full_name)
  end

  defp format_timezone_display(timezone) do
    case String.split(timezone, "/") do
      [_continent, city | _rest] -> String.replace(city, "_", " ")
      _other -> timezone
    end
  end
end
