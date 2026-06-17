defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Rhythm theme component for the confirmation/thank you step.
  Features clean, modern design with focus on readability.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

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
    <div class="scheduling-box" data-locale={@locale}>
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content confirmation-slide">
              <div class="confirmation-container">
                <div class="confirmation-header-section">
                  <div class="confirmation-title-row">
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
                        {dgettext("booking", "Successfully Rescheduled!")}
                      <% else %>
                        {dgettext("booking", "You're All Set!")}
                      <% end %>
                    </h1>
                  </div>

                  <p class="confirmation-message">
                    {dgettext("booking", "%{name}, your meeting %{organizer} is confirmed", name: @name, organizer: get_organizer_text(@organizer_profile))}
                  </p>
                </div>
                
                <div class="meeting-ticket">
                  <div class="ticket-header">
                    <span class="ticket-label">{dgettext("booking", "Meeting Details")}</span>
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
                        <span class="ticket-sublabel">{dgettext("booking", "Date")}</span>
                      </div>
                    </div>

                    <div class="ticket-row">
                      <div class="ticket-icon">
                        <.icon name="hero-clock" class="hero-icon hero-icon--md" />
                      </div>
                      <div class="ticket-info">
                        <span class="ticket-value">{@selected_time}</span>
                        <span class="ticket-sublabel">{Timezones.format(@user_timezone)}</span>
                      </div>
                    </div>

                    <%= if @organizer_profile do %>
                      <div class="ticket-row">
                        <div class="ticket-icon">
                          <.icon name="hero-user" class="hero-icon hero-icon--md" />
                        </div>
                        <div class="ticket-info">
                          <span class="ticket-value">
                            {Profiles.display_name(@organizer_profile)}
                          </span>
                          <span class="ticket-sublabel">{dgettext("booking", "Appointment host")}</span>
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
                          d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
                        />
                      </svg>
                      <span>{dgettext("booking", "Sent to")} <strong>{@email}</strong></span>
                    </div>
                  </div>
                </div>
                
                <%= if @custom_fields_snapshot && length(@custom_fields_snapshot) > 0 do %>
                  <section class="custom-answers-section">
                    <h3 class="custom-answers-heading">{dgettext("booking", "Your answers")}</h3>
                    <dl class="custom-answers-list">
                      <%= for d <- @custom_fields_snapshot do %>
                        <div class="custom-answer-row">
                          <dt class="custom-answer-label">{d["label"]}</dt>
                          <dd class="custom-answer-value">
                            {AnswerRenderer.render(d, @custom_field_answers[d["id"]])}
                          </dd>
                        </div>
                      <% end %>
                    </dl>
                  </section>
                <% end %>

                <div class="confirmation-actions-section">
                  <button
                    phx-click="schedule_another"
                    phx-target={@myself}
                    data-testid="schedule-another"
                    class="action-button-primary"
                  >
                    {dgettext("booking", "Schedule Another Meeting")}
                  </button>

                  <p class="help-text">
                    {dgettext("booking", "Need to make changes? Check your email for reschedule options")}
                  </p>
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
    case Profiles.display_name(organizer_profile) do
      nil -> ""
      name -> dgettext("booking", "with %{name}", name: name)
    end
  end
end
