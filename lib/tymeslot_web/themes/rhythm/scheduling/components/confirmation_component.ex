defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Rhythm theme component for the confirmation/thank you step.
  Features clean, modern design with focus on readability.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CustomFields.AnswerRenderer
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
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
                    {headline(assigns)}
                  </h1>
                </div>

                <p class="confirmation-message">
                  {confirmation_message(assigns)}
                </p>

                <ApprovalNotice.block
                  :if={Approval.required?(assigns[:meeting_type])}
                  organizer_name={Profiles.display_name(@organizer_profile)}
                  stage={:after}
                />
              </div>

              <div class="meeting-ticket">
                <div class="ticket-header">
                  <span class="ticket-label">{dgettext("booking", "Meeting Details")}</span>
                  <span class="ticket-badge">
                    {if @meeting_type, do: @meeting_type.duration_minutes, else: @duration} min
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

                  <div :if={@guest_emails not in [nil, []]} class="ticket-row">
                    <div class="ticket-icon">
                      <.icon name="hero-user-group" class="hero-icon hero-icon--md" />
                    </div>
                    <div class="ticket-info">
                      <span class="ticket-value">{Enum.join(@guest_emails, ", ")}</span>
                      <span class="ticket-sublabel">{dgettext("booking", "Guests")}</span>
                    </div>
                  </div>
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
                <a
                  :if={@meeting_uid not in [nil, ""] and @username_context not in [nil, ""]}
                  href={~p"/#{@username_context}/meeting/#{@meeting_uid}/calendar.ics"}
                  download
                  class="action-button-primary action-button-secondary calendar-download-button"
                  data-testid="add-to-calendar"
                >
                  <.icon name="hero-calendar-days" class="calendar-download-icon" />
                  {dgettext("booking", "Add to calendar")}
                </a>
                <button
                  phx-click="schedule_another"
                  phx-target={@myself}
                  data-testid="schedule-another"
                  class="action-button-primary"
                >
                  {dgettext("booking", "Schedule Another Meeting")}
                </button>

                <p class="help-text">
                  {dgettext(
                    "booking",
                    "Need to make changes? Check your email for reschedule options"
                  )}
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

  # See the Quill component: a held request must not be announced as a
  # confirmed meeting, heading included.
  defp headline(%{is_rescheduling: true}), do: dgettext("booking", "Successfully Rescheduled!")

  defp headline(assigns) do
    if Approval.required?(assigns[:meeting_type]) do
      dgettext("booking", "Request sent!")
    else
      dgettext("booking", "You're All Set!")
    end
  end

  defp confirmation_message(assigns) do
    organizer = get_organizer_text(assigns[:organizer_profile])

    if Approval.required?(assigns[:meeting_type]) do
      dgettext("booking", "%{name}, your request %{organizer} has been sent.",
        name: assigns[:name],
        organizer: organizer
      )
    else
      dgettext("booking", "%{name}, your meeting %{organizer} is confirmed",
        name: assigns[:name],
        organizer: organizer
      )
    end
  end
end
