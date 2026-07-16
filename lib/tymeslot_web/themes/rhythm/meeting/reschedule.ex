defmodule TymeslotWeb.Themes.Rhythm.Meeting.Reschedule do
  @moduledoc """
  Rhythm theme reschedule component with modern sliding style.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Themes.Shared.Components.MeetingDetails, only: [meeting_detail_rows: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.PathHandlers

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
      show_language_switcher={true}
    >
      <div class="scheduling-box">
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content confirmation-slide">
              <div class="confirmation-container">
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
                    {dgettext("booking", "Reschedule Appointment")}
                  </h1>

                  <p class="confirmation-message">
                    {dgettext("booking", "Select a new time for your meeting")}
                  </p>
                </div>
                
                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">{dgettext("booking", "Current Meeting Details")}</span>
                    <span class="ticket-badge">{@meeting.duration} min</span>
                  </div>

                  <.meeting_detail_rows
                    start_time={@meeting.start_time}
                    timezone={@meeting.attendee_timezone}
                    organizer_profile={@organizer_profile}
                    locale={@locale}
                    organizer_name={@meeting.organizer_name}
                    class="ticket-body"
                  />

                  <div class="ticket-footer">
                    <div class="email-confirmation">
                      <p class="ticket-footer-message">
                        {dgettext("booking", "Ready to pick a new time? Let's find one that works better for you.")}
                      </p>
                    </div>
                  </div>
                </div>
                
                <div class="confirmation-actions centered">
                  <button
                    phx-click={JS.navigate(PathHandlers.organizer_scheduling_path(assigns))}
                    class="action-button-primary"
                    type="button"
                  >
                    <span>{dgettext("booking", "Go to Calendar")}</span>
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
end
