defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.BookingComponent do
  @moduledoc """
  Folio's booking step: the slim masthead, a summary of the chosen time
  (with the day it ends on, when that is the next), the location choice (an
  option, video service or venue, or the one place already settled), the
  shared booking form (with the guest field) and
  the approval notice, then the way back and the submit button.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Folio.Components.Masthead
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
    <section class="folio-card folio-card--booking booker-card" data-locale={@locale}>
      <Masthead.masthead
        variant={:slim}
        theme_tokens={@theme_tokens}
        organizer_profile={@organizer_profile}
        username_context={@username_context}
        meeting_label={Masthead.meeting_label(assigns)}
      />

      <div class="folio-card__body">
        <header class="folio-step-header">
          <h1 class="folio-title">{dgettext("booking", "Enter Your Details")}</h1>
        </header>

        <dl class="folio-summary">
          <div class="folio-summary__item">
            <dt class="folio-eyebrow">{dgettext("booking", "Date")}</dt>
            <dd>{LocalizationHelpers.format_date(@selected_date)}</dd>
          </div>
          <div class="folio-summary__item">
            <dt class="folio-eyebrow">{dgettext("booking", "Time")}</dt>
            <dd>
              {LocalizationHelpers.format_slot_label(@selected_time) ||
                dgettext("booking", "No time selected")}
            </dd>
            <dd :if={@next_day_end} class="folio-summary__note" data-testid="booking-next-day-end">
              {@next_day_end}
            </dd>
          </div>
          <div class="folio-summary__item">
            <dt class="folio-eyebrow">{dgettext("booking", "Timezone")}</dt>
            <dd>{Timezones.format(@user_timezone)}</dd>
          </div>
          <div class="folio-summary__item">
            <dt class="folio-eyebrow">{dgettext("booking", "Duration")}</dt>
            <dd>{BookingText.duration_label(assigns)}</dd>
          </div>
        </dl>

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

        <div class="folio-booking">
          <BookingForm.booking_form
            form={@form}
            validation_errors={@validation_errors}
            target={@myself}
            class="folio-booking-form"
            contact_class="folio-contact"
            message_rows={4}
            labels={form_labels()}
          >
            <GuestField.guest_field
              :if={GuestBooking.guests_allowed?(assigns)}
              guest_emails={@guest_emails}
              guest_input={@guest_input}
              guest_error={@guest_error}
              guests_open={@guests_open}
              max_guests={@max_guests}
              target={@myself}
            />
          </BookingForm.booking_form>
        </div>

        <ApprovalNotice.block
          :if={Approval.required?(@meeting_type)}
          organizer_name={BookingLabels.organizer_display_name(@organizer_profile, @username_context)}
          payment_required={@meeting_type.payment_required}
          stage={:before}
        />

        <div class="folio-actions">
          <button
            type="button"
            class="folio-button folio-button--quiet"
            phx-click="back_step"
            phx-target={@myself}
            data-testid="back-step"
            data-intent="back"
            disabled={@submitting}
          >
            <.icon name="hero-arrow-left-mini" class="folio-button__icon" />
            {dgettext("booking", "Back")}
          </button>
          <button
            type="submit"
            form="booking-form"
            class="folio-button folio-button--primary"
            data-testid="submit-booking"
            data-intent="submit"
            disabled={@submitting || !OrganizerHelpers.form_valid?(@form)}
          >
            <%= if @submitting do %>
              <span class="folio-spinner" aria-hidden="true"></span>
              <span>{dgettext("booking", "Verifying...")}</span>
            <% else %>
              {BookingLabels.submit_label(
                @is_rescheduling,
                @meeting_type,
                dgettext("booking", "Submit"),
                :folio
              )}
            <% end %>
          </button>
        </div>
      </div>
    </section>
    """
  end

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
