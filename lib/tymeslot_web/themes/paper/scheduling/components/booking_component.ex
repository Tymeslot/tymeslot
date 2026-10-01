defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.BookingComponent do
  @moduledoc """
  Paper's booking step: the chosen meeting, day, time, length, timezone
  and price in a quiet box at the top of the card, then where to meet, the
  shared booking form (name and email side by side once the card is wide
  enough) with the guest field, the approval notice for a gated type, and
  Back and the submit button.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Timezones
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Paper.Components
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
    assigns =
      assign(assigns,
        when_text:
          dgettext("booking", "%{date} at %{time}",
            date: LocalizationHelpers.format_date(assigns.selected_date),
            time:
              LocalizationHelpers.format_slot_label(assigns.selected_time) ||
                dgettext("booking", "No time selected")
          ),
        duration_text:
          BookingText.duration_label(%{
            meeting_type: assigns.meeting_type,
            duration: assigns.duration
          }),
        price:
          BookingText.price_label(assigns.meeting_type, assigns.host_currency, assigns.locale)
      )

    ~H"""
    <section class="paper-card booker-card" data-locale={@locale} data-testid="paper-booking">
      <Components.brand theme_tokens={@theme_tokens} />

      <div class="paper-summary">
        <p :if={@meeting_type} class="paper-summary__title">{@meeting_type.name}</p>
        <ul class="paper-facts" role="list">
          <Components.fact icon="hero-calendar">{@when_text}</Components.fact>
          <Components.fact icon="hero-clock">{@duration_text}</Components.fact>
          <Components.fact icon="hero-globe-alt">{Timezones.format(@user_timezone)}</Components.fact>
          <Components.fact :if={@price} icon="hero-banknotes">{@price}</Components.fact>
        </ul>
      </div>

      <h1 class="paper-heading paper-booking__title">{dgettext("booking", "Enter Your Details")}</h1>

      <LocationField.location_field
        :if={BookingLocation.choice_required?(assigns)}
        location_options={@location_options}
        selected_location_id={@selected_location_id}
        video_choices={BookingLocation.video_choices(assigns)}
        selected_video_id={@selected_video_id}
        location_phone={@location_phone}
        location_error={@location_error}
        phone_required={BookingLocation.phone_required?(assigns)}
        target={@myself}
      />

      <BookingForm.booking_form
        form={@form}
        validation_errors={@validation_errors}
        target={@myself}
        class="paper-booking-form"
        contact_class="paper-booking-form__contact"
        message_rows={3}
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

      <ApprovalNotice.block
        :if={Approval.required?(@meeting_type)}
        organizer_name={BookingLabels.organizer_display_name(@organizer_profile, @username_context)}
        payment_required={@meeting_type.payment_required}
        stage={:before}
      />

      <div class="paper-actions paper-actions--split">
        <button
          type="button"
          class="paper-button paper-button--quiet"
          phx-click="back_step"
          phx-target={@myself}
          data-testid="back-step"
          disabled={@submitting}
        >
          <.icon name="hero-arrow-left-mini" class="paper-button__icon" />
          {dgettext("booking", "Back")}
        </button>
        <button
          type="submit"
          form="booking-form"
          class="paper-button paper-button--primary"
          data-testid="submit-booking"
          disabled={@submitting || !OrganizerHelpers.form_valid?(@form)}
        >
          <%= if @submitting do %>
            <svg class="paper-spinner" viewBox="0 0 24 24" fill="none" aria-hidden="true">
              <circle
                class="paper-spinner__track"
                cx="12"
                cy="12"
                r="10"
                stroke="currentColor"
                stroke-width="3"
              />
              <path
                class="paper-spinner__head"
                d="M22 12a10 10 0 0 0-10-10"
                stroke="currentColor"
                stroke-width="3"
                stroke-linecap="round"
              />
            </svg>
            <span>{dgettext("booking", "Verifying...")}</span>
          <% else %>
            {BookingLabels.submit_label(
              @is_rescheduling,
              @meeting_type,
              dgettext("booking", "Book Meeting")
            )}
          <% end %>
        </button>
      </div>
    </section>
    """
  end
end
