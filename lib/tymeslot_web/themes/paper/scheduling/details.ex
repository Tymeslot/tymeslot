defmodule TymeslotWeb.Themes.Paper.Scheduling.Details do
  @moduledoc """
  The lower part of Paper's schedule screen, once a time is picked
  (`ScheduleComponent`): a heading, the chosen day and time, the meeting
  type's questions all at once (`CustomQuestions.Events.all_questions/1`),
  then where to meet, the shared booking form with the guest field, the
  approval notice and the submit button. The one submit sends the answers
  with the details; the submission validates them, and a question it
  refused shows its error under it until the answer is put right.

  It renders with the schedule component's own assigns (`{assigns}`), plus
  `target` (the component's `@myself`, which every control targets). A
  question's form submits `next_step` on Enter, which the schedule
  component drops: the screen has no way on, and the questions never step.

  The heading takes the keyboard focus when the part first appears (a time
  just picked), which on a phone scrolls the questions and the form into
  view. No question input takes the focus itself (`autofocus={false}`).
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents.Icons, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias Tymeslot.Meetings.Approval
  alias TymeslotWeb.Live.Scheduling.OrganizerHelpers
  alias TymeslotWeb.Themes.Shared.BookingLabels
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.BookingForm
  alias TymeslotWeb.Themes.Shared.Components.GuestField
  alias TymeslotWeb.Themes.Shared.Components.LocationField
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @doc "The details part: the heading, the chosen time, the questions and the form."
  @spec book(map()) :: Phoenix.LiveView.Rendered.t()
  def book(assigns) do
    assigns =
      assign(assigns,
        next_day_end: LocalizationHelpers.booking_next_day_end(assigns),
        questions: Events.all_questions(assigns)
      )

    ~H"""
    <section class="paper-book" data-testid="paper-book" aria-labelledby="paper-book-heading">
      <h2
        id="paper-book-heading"
        class="paper-heading paper-book__title"
        tabindex="-1"
        phx-mounted={JS.focus()}
      >
        {dgettext("booking", "Enter Your Details")}
      </h2>
      <p class="paper-book__when" data-testid="paper-book-when">
        <.icon name="hero-calendar" class="paper-book__when-icon" />
        <span>
          {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
        </span>
      </p>
      <p
        :if={@next_day_end}
        class="paper-book__when paper-book__when--end"
        data-testid="booking-next-day-end"
      >
        {@next_day_end}
      </p>
      <.questions questions={@questions} target={@target} />
      <.form_part {assigns} />
    </section>
    """
  end

  # Every question at once, in the definitions' order, each with the error
  # the submission (or a touched answer) gave it. Nothing when the meeting
  # type has none.
  attr :questions, :list, required: true
  attr :target, :any, required: true

  defp questions(assigns) do
    ~H"""
    <div :if={@questions != []} class="paper-book__questions" data-testid="paper-questions">
      <div
        :for={{question, index} <- Enum.with_index(@questions)}
        class="paper-question"
        data-testid="paper-question"
        data-index={index}
      >
        <h3 class="paper-question__label">{question.definition["label"]}</h3>
        <p :if={question.definition["help_text"]} class="paper-question__help">
          {question.definition["help_text"]}
        </p>

        <div class={["paper-question__input", question.error && "paper-question__input--invalid"]}>
          <InputRenderer.render
            definition={question.definition}
            value={question.value}
            myself={@target}
            autofocus={false}
          />
        </div>

        <p :if={question.error} class="paper-question__error" role="alert">{question.error}</p>
      </div>
    </div>
    """
  end

  defp form_part(assigns) do
    ~H"""
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
      target={@target}
    />

    <LocationField.stated_location
      :if={BookingLocation.stated_location?(assigns)}
      option={BookingLocation.selected(assigns)}
      venue_choices={BookingLocation.venue_choices(assigns)}
    />

    <BookingForm.booking_form
      form={@form}
      validation_errors={@validation_errors}
      target={@target}
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
        target={@target}
      />
    </BookingForm.booking_form>

    <ApprovalNotice.block
      :if={Approval.required?(@meeting_type)}
      organizer_name={BookingLabels.organizer_display_name(@organizer_profile, @username_context)}
      payment_required={@meeting_type.payment_required}
      stage={:before}
    />

    <div class="paper-actions paper-book__actions">
      <button
        type="submit"
        form="booking-form"
        class="paper-button paper-button--primary"
        data-testid="submit-booking"
        data-intent="submit"
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
            dgettext("booking", "Book Meeting"),
            :paper
          )}
        <% end %>
      </button>
    </div>
    """
  end
end
