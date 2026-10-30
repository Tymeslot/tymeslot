defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.YouMoment do
  @moduledoc """
  The details, which open below the time once one is picked: a heading, the
  chosen day and time (with the day it ends on, when that is the next),
  then the meeting type's questions one at a time while this booking has
  some to confirm (the shared inputs, Continue, and the previous question
  past the first), then where to meet (an option, video service or venue,
  or the one place already settled), the shared booking form with the guest
  field, the approval notice, a paid type's price and the submit.

  The form exists once the attendee fact is entered, which the runtime does
  as the moment opens (the time is known by then, and answers asked beside
  the form are no prerequisite of it); this moment shows it only once the
  questions are confirmed with Continue. The questions' events go to the
  shared questions engine, every other event to `StepEvents`.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Shared.BookingLabels
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.BookingForm
  alias TymeslotWeb.Themes.Shared.Components.GuestField
  alias TymeslotWeb.Themes.Shared.Components.LocationField
  alias TymeslotWeb.Themes.Shared.Components.SubmitPrice
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.Journey.Components, as: JourneyComponents
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Answers
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.StepEvents

  @question_events ~w(answer multi_toggle)

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def handle_event(event, params, socket) when event in @question_events,
    do: Events.handle_event(event, params, socket)

  # The visitor's own Continue or Back. The questions block loses the
  # control that held the focus when the last answer is confirmed (Continue
  # goes with the block) and when Back reaches the first question (Back
  # goes), and `:journey_focus` does not move, as the moment stays current.
  # `:focus_after` says where the focus goes once the screen has changed;
  # the markup acts on it only for the stage it names, so a deep link or a
  # plain mount, which never send these events, move nothing.
  def handle_event("next_step", params, socket),
    do:
      socket
      |> assign(:focus_after, :details)
      |> then(&Events.handle_event("next_step", params, &1))

  def handle_event("back_step", params, socket),
    do:
      socket
      |> assign(:focus_after, :question)
      |> then(&Events.handle_event("back_step", params, &1))

  def handle_event(event, params, socket), do: StepEvents.handle_event(event, params, socket)

  @impl Phoenix.LiveComponent
  def render(assigns) do
    stage = stage(assigns)

    assigns =
      assign(assigns,
        stage: stage,
        next_day_end: LocalizationHelpers.booking_next_day_end(assigns),
        focus_after: assigns[:focus_after]
      )

    assigns = if stage == :questions, do: Events.assign_render_state(assigns), else: assigns

    ~H"""
    <section
      id={"#{@moment}-step"}
      class="folio-section folio-you booker-card"
      data-moment={@moment}
      data-moment-state={@moment_state}
    >
      <JourneyComponents.moment_heading
        moment={@moment}
        moment_state={@moment_state}
        focus={assigns[:journey_focus]}
        class="folio-section__title"
      >
        {dpgettext("booking_voice", "folio", "A little about you")}
      </JourneyComponents.moment_heading>
      <p class="folio-you__when" data-testid="folio-you-when">
        {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
      </p>
      <p
        :if={@next_day_end}
        class="folio-you__when folio-you__when--end"
        data-testid="booking-next-day-end"
      >
        {@next_day_end}
      </p>

      <.questions :if={@stage == :questions} {assigns} />
      <.details :if={@stage == :details} {assigns} />
    </section>
    """
  end

  defp questions(assigns) do
    ~H"""
    <div class="folio-questions" data-testid="folio-questions">
      <div :if={@total > 1} class="folio-progress">
        <span class="folio-eyebrow">
          {dgettext("booking", "Question %{n} of %{m}", n: @index + 1, m: @total)}
        </span>
        <span
          class="folio-progress__track"
          role="progressbar"
          aria-label={dgettext("booking", "Question %{n} of %{m}", n: @index + 1, m: @total)}
          aria-valuenow={@index + 1}
          aria-valuemin={1}
          aria-valuemax={@total}
        >
          <span class="folio-progress__bar" style={"width: #{div((@index + 1) * 100, @total)}%"}></span>
        </span>
      </div>

      <h3
        id={"folio-question-#{@index}"}
        class="folio-question__label"
        tabindex="-1"
        phx-mounted={(@focus_after == :question and @index == 0) && JS.focus()}
      >
        {@definition["label"]}
      </h3>
      <p :if={@definition["help_text"]} class="folio-muted">{@definition["help_text"]}</p>

      <div class="folio-question">
        <InputRenderer.render definition={@definition} value={@value} myself={@myself} />
        <p :if={@error} class="folio-error" role="alert">{@error}</p>
      </div>

      <div class="folio-actions">
        <button
          :if={@index > 0}
          type="button"
          class="folio-button folio-button--quiet"
          phx-click="back_step"
          data-intent="back"
          phx-target={@myself}
        >
          <.icon name="hero-arrow-left-mini" class="folio-button__icon" />
          {dgettext("booking", "Back")}
        </button>
        <button
          type="button"
          class="folio-button folio-button--primary"
          phx-click="next_step"
          data-intent="continue"
          phx-target={@myself}
        >
          {dgettext("booking", "Continue")}
          <.icon name="hero-arrow-right-mini" class="folio-button__icon" />
        </button>
      </div>
    </div>
    """
  end

  defp details(assigns) do
    ~H"""
    <div
      id="folio-details"
      role="group"
      tabindex="-1"
      aria-labelledby={"#{@moment}-heading-#{@moment_state}"}
      phx-mounted={@focus_after == :details && JS.focus()}
    >
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
          labels={BookingForm.short_labels()}
        >
          <GuestField.guest_field
            :if={GuestBooking.guests_allowed?(assigns)}
            guest_emails={@guest_emails}
            guest_input={@guest_input}
            guest_error={@guest_error}
            guests_open={@guests_open}
            max_guests={@max_guests}
            show_cap={@guest_cap_visible}
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

      <div class="folio-actions folio-actions--in-order">
        <SubmitPrice.price
          meeting_type={@meeting_type}
          currency={@host_currency}
          locale={@locale}
          rescheduling={@is_rescheduling}
          class="folio-booking__price"
        />
        <button
          type="submit"
          form="booking-form"
          class="folio-button folio-button--primary"
          data-testid="submit-booking"
          aria-describedby={
            SubmitPrice.describedby(@meeting_type, @host_currency, @locale, @is_rescheduling)
          }
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
    """
  end

  # The questions this booking has not confirmed, one at a time, then the
  # form, which exists once the attendee fact was entered (as the moment
  # opened).
  defp stage(assigns) do
    cond do
      Answers.required?(assigns) and not Engine.confirmed?(assigns.engine) -> :questions
      match?(%Phoenix.HTML.Form{}, assigns[:form]) -> :details
      true -> :none
    end
  end
end
