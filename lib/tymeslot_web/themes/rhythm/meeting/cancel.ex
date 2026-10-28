defmodule TymeslotWeb.Themes.Rhythm.Meeting.Cancel do
  @moduledoc """
  Rhythm theme cancel component with modern sliding style.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  import TymeslotWeb.Themes.Shared.Components.MeetingDetails, only: [meeting_detail_rows: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  attr :theme_tokens, :any, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true
  attr :meeting, :map, required: true
  attr :organizer_profile, :map, default: nil
  attr :loading, :boolean, required: true
  attr :meeting_kept, :boolean, default: false

  @doc """
  Renders the cancel page in Rhythm theme style.
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
                  <%= if @meeting_kept do %>
                    <div class="success-badge success-badge--transparent">
                      <div class="success-badge-inner success-badge-inner--success">
                        <.icon name="hero-check-circle" class="success-icon stroke-2" />
                      </div>
                    </div>

                    <h1 class="confirmation-headline">
                      {dgettext("booking_manage", "Meeting Confirmed")}
                    </h1>

                    <p class="confirmation-message">
                      {dgettext(
                        "booking_manage",
                        "Great! Your meeting is still scheduled as planned."
                      )}
                    </p>
                  <% else %>
                    <div class="success-badge success-badge--transparent">
                      <div class="success-badge-inner success-badge-inner--danger">
                        <.icon name="hero-x-mark" class="success-icon stroke-2" />
                      </div>
                    </div>

                    <h1 class="confirmation-headline">
                      {dgettext("booking_manage", "Cancel Appointment")}
                    </h1>

                    <p class="confirmation-message">
                      {dgettext("booking_manage", "Are you sure you want to cancel this appointment?")}
                    </p>
                  <% end %>
                </div>

                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">{dgettext("booking_manage", "Meeting Details")}</span>
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

                  <%= if @meeting_kept do %>
                    <div class="ticket-footer">
                      <div class="email-confirmation">
                        <.icon name="hero-check-circle" class="email-icon email-icon--success" />
                        <span>{dgettext(
                          "booking_manage",
                          "We look forward to seeing you at the scheduled time."
                        )}</span>
                      </div>
                    </div>
                  <% else %>
                    <div class="ticket-footer">
                      <div class="email-confirmation">
                        <.icon name="hero-exclamation-triangle" class="email-icon" />
                        <span>{dgettext(
                          "booking_manage",
                          "A cancellation email will be sent to all participants"
                        )}</span>
                      </div>
                    </div>
                  <% end %>
                </div>

                <%= if @meeting_kept do %>
                  <div class="confirmation-actions centered">
                    <button
                      phx-click={JS.navigate("/")}
                      class="action-button-primary action-button-success"
                      type="button"
                    >
                      {dgettext("booking_manage", "Done")}
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
                        {dgettext("booking_manage", "Cancelling...")}
                      <% else %>
                        {dgettext("booking_manage", "Yes, Cancel Meeting")}
                      <% end %>
                    </button>

                    <button
                      phx-click="keep_meeting"
                      class="action-button-primary action-button-secondary"
                      type="button"
                      data-testid="keep-meeting"
                      disabled={@loading}
                    >
                      {dgettext("booking_manage", "Keep Meeting")}
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
