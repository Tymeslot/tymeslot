defmodule TymeslotWeb.Themes.Rhythm.Meeting.Reschedule do
  @moduledoc """
  Rhythm theme reschedule component with modern sliding style.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  import TymeslotWeb.Themes.Shared.Components.MeetingDetails, only: [meeting_detail_rows: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.PathHandlers

  attr :theme_tokens, :any, required: true
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
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="scheduling-box booker-card">
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content confirmation-slide">
              <div class="confirmation-container">
                <div class="confirmation-header-section">
                  <div class="success-badge">
                    <div class="success-badge-inner success-badge-inner--info">
                      <.icon name="hero-arrow-path" class="success-icon stroke-2" />
                    </div>
                  </div>

                  <h1 class="confirmation-headline">
                    {dgettext("booking_manage", "Reschedule Appointment")}
                  </h1>

                  <p class="confirmation-message">
                    {dgettext("booking_manage", "Select a new time for your meeting")}
                  </p>
                </div>

                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">{dgettext("booking_manage", "Current Meeting Details")}</span>
                    <span class="ticket-badge">{dgettext("booking_manage", "%{minutes} min",
                      minutes: @meeting.duration
                    )}</span>
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
                        {dgettext(
                          "booking_manage",
                          "Ready to pick a new time? Let's find one that works better for you."
                        )}
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
                    <span>{dgettext("booking_manage", "Go to Calendar")}</span>
                    <.icon name="hero-calendar" class="icon-sm" />
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
