defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Rhythm theme component for the confirmation/thank you step.
  Features clean, modern design with focus on readability.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Shared.ApprovalDisplay
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.ChosenLength
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.CustomAnswers
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.LocationField
  alias TymeslotWeb.Themes.Shared.Components.MeetingPrice
  alias TymeslotWeb.Themes.Shared.ConfirmationText
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.PathHandlers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :next_day_end, LocalizationHelpers.booking_next_day_end(assigns))

    ~H"""
    <div class="scheduling-box booker-card" data-locale={@locale} data-testid="booker-card">
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content confirmation-slide">
            <div class="confirmation-container">
              <div class="confirmation-header-section">
                <div class="confirmation-title-row">
                  <div class={[
                    "success-badge",
                    ApprovalDisplay.awaiting_approval?(assigns) && "success-badge--pending"
                  ]}>
                    <div class={[
                      "success-badge-inner",
                      ApprovalDisplay.awaiting_approval?(assigns) && "success-badge-inner--pending"
                    ]}>
                      <.icon
                        :if={!ApprovalDisplay.awaiting_approval?(assigns)}
                        name="hero-check"
                        class="success-icon stroke-3"
                      />
                      <.icon
                        :if={ApprovalDisplay.awaiting_approval?(assigns)}
                        name="hero-clock"
                        class="success-icon stroke-3"
                      />
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
                  :if={ApprovalDisplay.awaiting_approval?(assigns)}
                  organizer_name={Profiles.display_name(@organizer_profile)}
                  stage={:after}
                />

                <GroupSession.confirmation_line meeting_type={@meeting_type} />
              </div>

              <div class="meeting-ticket">
                <div class="ticket-header">
                  <span class="ticket-label">{dgettext("booking", "Meeting Details")}</span>
                  <span class="ticket-badge">
                    {dgettext("booking", "%{minutes} min",
                      minutes:
                        Offer.duration_minutes(
                          @meeting_type,
                          @duration,
                          ChosenLength.minutes(assigns)
                        )
                    )}
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
                      <span class="ticket-value">
                        {LocalizationHelpers.format_slot_label(@selected_time)}
                      </span>
                      <span class="ticket-sublabel">{Timezones.format(@user_timezone)}</span>
                      <span
                        :if={@next_day_end}
                        class="ticket-sublabel"
                        data-testid="booking-next-day-end"
                      >
                        {@next_day_end}
                      </span>
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

                  <div
                    :if={BookingLocation.chosen_display(assigns)}
                    class="ticket-row"
                    data-testid="confirmation-location"
                  >
                    <div class="ticket-icon">
                      <.icon name="hero-map-pin" class="hero-icon hero-icon--md" />
                    </div>
                    <div class="ticket-info">
                      <span class="ticket-value">{BookingLocation.chosen_display(assigns)}</span>
                      <span class="ticket-sublabel">{dgettext("booking", "Location")}</span>
                      <LocationField.arranged_note :if={
                        BookingLocation.arranged_after_booking?(assigns)
                      } />
                    </div>
                  </div>

                  <div
                    :if={MeetingPrice.paid_price(assigns[:paid_payment], @locale)}
                    class="ticket-row"
                    data-testid="confirmation-paid"
                  >
                    <div class="ticket-icon">
                      <.icon name="hero-credit-card" class="hero-icon hero-icon--md" />
                    </div>
                    <div class="ticket-info">
                      <span class="ticket-value">{MeetingPrice.paid_price(@paid_payment, @locale)}</span>
                      <span class="ticket-sublabel">{dgettext("booking", "Paid")}</span>
                    </div>
                  </div>

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
                    <.icon name="hero-envelope" class="email-icon" />
                    <span>{dgettext("booking", "Sent to")} <strong>{@email}</strong></span>
                  </div>
                </div>
              </div>

              <CustomAnswers.custom_answers
                snapshot={@custom_fields_snapshot}
                answers={@custom_field_answers}
              />

              <div class="confirmation-actions-section">
                <a
                  :if={PathHandlers.calendar_ics_path(assigns)}
                  href={PathHandlers.calendar_ics_path(assigns)}
                  download
                  class="action-button-primary action-button-secondary calendar-download-button"
                  data-testid="add-to-calendar"
                >
                  <.icon name="hero-calendar-days" class="calendar-download-icon" />
                  {if ApprovalDisplay.awaiting_approval?(assigns),
                    do: dgettext("booking", "Add tentative hold to calendar"),
                    else: dgettext("booking", "Add to calendar")}
                </a>
                <button
                  phx-click="schedule_another"
                  phx-target={@myself}
                  data-testid="schedule-another"
                  data-intent="restart"
                  class="action-button-primary"
                >
                  {dgettext("booking", "Schedule Another Meeting")}
                </button>

                <p class="help-text">
                  {if ApprovalDisplay.awaiting_approval?(assigns),
                    do:
                      dgettext(
                        "booking",
                        "Changed your mind? Your request email has a link to withdraw it."
                      ),
                    else:
                      dgettext(
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
  # Which status applies is decided in ConfirmationText (a held request must
  # not be announced as a confirmed meeting); only the wording is Rhythm's.
  defp headline(assigns) do
    case ConfirmationText.status(assigns) do
      :held -> dgettext("booking", "Request sent!")
      :rescheduled -> dgettext("booking", "Successfully Rescheduled!")
      :confirmed -> dgettext("booking", "You're All Set!")
    end
  end

  defp confirmation_message(assigns) do
    case ConfirmationText.status(assigns) do
      :held ->
        ConfirmationText.held_message(assigns[:name], assigns[:organizer_profile], :rhythm)

      _confirmed_or_rescheduled ->
        dgettext("booking", "%{name}, your meeting %{organizer} is confirmed",
          name: assigns[:name],
          organizer: ConfirmationText.organizer_fragment(assigns[:organizer_profile], :rhythm)
        )
    end
  end
end
