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

  The heading takes the keyboard focus when the part appears after the
  visitor picked a time in this page view (`focus_details`, set by the
  schedule component), which on a phone scrolls the questions and the form
  into view; a deep link to /book never moves the focus on load, as with
  `Journey.Components.moment_heading/1`. No question input takes the focus itself (`autofocus={false}`).

  The chosen time carries "Change time", which takes the focus back to that
  time in the picker (the month's selected time, or the week's pressed one),
  so a visitor on a long screen gets back to the picker in one press. In the
  week view the chosen time stays chosen while the visitor pages to another
  week, and its button leaves the page with that week; the chip shows only
  while the week on screen holds the chosen day, since it would focus nothing.
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
  alias TymeslotWeb.Themes.Shared.Components.SubmitPrice
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Events
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer, as: InputRenderer
  alias TymeslotWeb.Themes.Shared.GuestBooking
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  # The month's selection is cleared by paging, so it is always on screen; a
  # week's is on screen while the chosen day falls in the week shown.
  defp time_on_screen?(%{view: "week", selected_date: date, current_week_start: start})
       when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, day} ->
        Date.compare(day, start) != :lt and Date.compare(day, Date.add(start, 6)) != :gt

      _invalid ->
        false
    end
  end

  defp time_on_screen?(%{view: "week"}), do: false
  defp time_on_screen?(_assigns), do: true

  @doc "The details part: the heading, the chosen time, the questions and the form."
  @spec book(map()) :: Phoenix.LiveView.Rendered.t()
  def book(assigns) do
    assigns =
      assign(assigns,
        next_day_end: LocalizationHelpers.booking_next_day_end(assigns),
        questions: Events.all_questions(assigns),
        can_change_time: time_on_screen?(assigns)
      )

    ~H"""
    <section class="paper-book" data-testid="paper-book" aria-labelledby="paper-book-heading">
      <%!-- Keyed by the visitor's pick count, so every pick mounts a fresh
           heading and its phx-mounted runs again, also after "Change time"
           (the section itself stays mounted, so it would not fire twice). --%>
      <div id={"paper-book-head-#{assigns[:pick_seq] || 0}"} class="paper-book__head">
        <h2
          id="paper-book-heading"
          class="paper-heading paper-book__title"
          tabindex="-1"
          phx-mounted={
            assigns[:focus_details] &&
              JS.add_class("paper-card--booking", to: "#schedule-step") |> JS.focus()
          }
        >
          {dpgettext("booking_voice", "paper", "Enter your details")}
        </h2>
      </div>
      <p class="paper-book__when" data-testid="paper-book-when">
        <.icon name="hero-calendar" class="paper-book__when-icon" />
        <span>
          {LocalizationHelpers.format_booking_datetime(@selected_date, @selected_time, @user_timezone)}
        </span>
        <button
          :if={@can_change_time}
          type="button"
          class="paper-book__change"
          data-testid="paper-change-time"
          phx-click={
            JS.remove_class("paper-card--booking", to: "#schedule-step")
            |> JS.focus(
              to:
                "#schedule-step .slot-list__slot--selected, #schedule-step [data-fact='slot'][aria-pressed='true']"
            )
          }
        >
          {dpgettext("booking_voice", "paper", "Change time")}
        </button>
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
        <h3 class="paper-question__label">
          {question.definition["label"]}
          <%!-- The marker Name and Email carry. Its input states the requirement
               (`aria-required`), so the asterisk is decoration. --%>
          <span
            :if={question.definition["required"] == true}
            class="text-red-500 ml-0.5"
            aria-hidden="true"
            data-testid="paper-question-required"
          >*</span>
        </h3>
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
      labels={BookingForm.short_labels()}
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

    <SubmitPrice.price
      meeting_type={@meeting_type}
      currency={@host_currency}
      locale={@locale}
      rescheduling={@is_rescheduling}
      class="paper-book__price"
    />

    <div class="paper-actions paper-book__actions">
      <button
        type="submit"
        form="booking-form"
        class="paper-button paper-button--primary"
        data-testid="submit-booking"
        aria-describedby={
          SubmitPrice.describedby(@meeting_type, @host_currency, @locale, @is_rescheduling)
        }
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
          <span>{dpgettext("booking_voice", "paper", "Sending…")}</span>
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
