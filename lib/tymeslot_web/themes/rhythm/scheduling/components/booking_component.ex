defmodule TymeslotWeb.Themes.Rhythm.Scheduling.Components.BookingComponent do
  @moduledoc """
  Rhythm theme component for the booking/contact form step.
  Updated to use form struct and shared patterns.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Rhythm.Shared.OrganizerHeader
  alias TymeslotWeb.Themes.Shared.BookingLabels
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.BookingForm
  alias TymeslotWeb.Themes.Shared.Components.GuestField
  alias TymeslotWeb.Themes.Shared.Components.LocationField
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns = assign(assigns, :next_day_end, LocalizationHelpers.booking_next_day_end(assigns))

    ~H"""
    <div class="scheduling-box booker-card" data-locale={@locale}>
      <div class="slide-container">
        <div class="slide active">
          <div class="slide-content booking-slide">
            <div class="schedule-header">
              <OrganizerHeader.organizer_header_small
                organizer_profile={@organizer_profile}
                meeting_type={@meeting_type}
                selected_duration={@duration}
              />
            </div>

            <div class="meeting-summary compact">
              <div class="summary-row">
                <div class="summary-item">
                  <.icon name="hero-calendar" class="summary-icon hero-icon hero-icon--md" />
                  <div>
                    <div class="summary-value">{LocalizationHelpers.format_date(@selected_date)}</div>
                    <div class="summary-label">
                      {LocalizationHelpers.format_slot_label(@selected_time) ||
                        dgettext("booking", "No time selected")}
                    </div>
                    <div :if={@next_day_end} class="summary-label" data-testid="booking-next-day-end">
                      {@next_day_end}
                    </div>
                  </div>
                </div>
                <div class="summary-item">
                  <.icon name="hero-globe-alt" class="summary-icon hero-icon hero-icon--md" />
                  <div>
                    <div class="summary-value">
                      {Timezones.format(@user_timezone)}
                    </div>
                    <div class="summary-label">
                      {BookingText.duration_label(%{
                        meeting_type: @meeting_type,
                        duration: @selected_duration
                      })} {dgettext(
                        "booking",
                        "meeting"
                      )}
                    </div>
                  </div>
                </div>
              </div>
            </div>

            <LocationField.location_field
              :if={BookingLocation.choice_required?(assigns)}
              location_options={@location_options}
              selected_location_id={@selected_location_id}
              video_choices={BookingLocation.video_choices(assigns)}
              selected_video_id={@selected_video_id}
              venue_choices={BookingLocation.venue_choices(assigns)}
              selected_venue_id={@selected_venue_id}
              kept_location={BookingLocation.kept_location(assigns)}
              location_phone={@location_phone}
              location_error={@location_error}
              phone_required={BookingLocation.phone_required?(assigns)}
              target={@myself}
            />

            <LocationField.stated_location
              :if={BookingLocation.stated_location?(assigns)}
              option={BookingLocation.selected(assigns)}
              venue_choices={BookingLocation.venue_choices(assigns)}
            />

            <BookingForm.booking_form
              form={@form}
              validation_errors={@validation_errors}
              target={@myself}
              class="booking-form"
              message_rows={4}
              labels={form_labels()}
            >
              <GuestField.guest_field
                :if={guests_allowed?(assigns)}
                guest_emails={@guest_emails}
                guest_input={@guest_input}
                guest_error={@guest_error}
                guests_open={@guests_open}
                max_guests={@max_guests}
                target={@myself}
              />
            </BookingForm.booking_form>

            <ApprovalNotice.block
              :if={Approval.required?(@meeting_type)}
              organizer_name={organizer_display_name(@organizer_profile, @username_context)}
              payment_required={@meeting_type.payment_required}
              stage={:before}
            />

            <div class="slide-actions horizontal">
              <button
                type="button"
                class="prev-button"
                phx-click="back_step"
                phx-target={@myself}
                data-testid="back-step"
                data-intent="back"
                disabled={@submitting}
              >
                ← {dgettext("booking", "Back")}
              </button>
              <button
                type="submit"
                form="booking-form"
                class="submit-button"
                data-testid="submit-booking"
                data-intent="submit"
                disabled={@submitting || !OrganizerHelpers.form_valid?(@form)}
              >
                <%= if @submitting do %>
                  <svg
                    class="loading-spinner icon-sm"
                    xmlns="http://www.w3.org/2000/svg"
                    fill="none"
                    viewBox="0 0 24 24"
                  >
                    <circle
                      class="loading-spinner-track"
                      cx="12"
                      cy="12"
                      r="10"
                      stroke="currentColor"
                      stroke-width="4"
                    >
                    </circle>
                    <path
                      class="loading-spinner-path"
                      fill="currentColor"
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    >
                    </path>
                  </svg>
                  <span>{dgettext("booking", "Verifying...")}</span>
                <% else %>
                  {submit_label(@is_rescheduling, @meeting_type)}
                <% end %>
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp guests_allowed?(assigns), do: GuestBooking.guests_allowed?(assigns)

  # "Submit" is vague enough to survive a gated meeting type, but naming the
  # action makes the difference visible at the moment of committing —
  # including on a reschedule, which re-enters the approval gate on a gated
  # type just as a fresh submission does.
  defp submit_label(is_rescheduling, meeting_type) do
    BookingLabels.submit_label(
      is_rescheduling,
      meeting_type,
      dgettext("booking", "Submit"),
      :rhythm
    )
  end

  defp organizer_display_name(organizer_profile, username_context) do
    BookingLabels.organizer_display_name(organizer_profile, username_context)
  end

  # Rhythm's shorter field labels.
  defp form_labels do
    %{
      name: dgettext("booking", "Name"),
      name_placeholder: dgettext("booking", "Enter your full name"),
      email: dgettext("booking", "Email"),
      email_placeholder: dgettext("booking", "your.email@example.com"),
      message: dgettext("booking", "Message (optional)"),
      message_placeholder: dgettext("booking", "Add any details...")
    }
  end
end
