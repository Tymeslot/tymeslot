defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Folio's confirmation step: the full masthead, the outcome (confirmed,
  rescheduled, or a request awaiting the organiser's approval) with its
  badge, for a group type the line saying the booking is one of its spots,
  the meeting's details (with the day it ends on, when that is the next, and
  a note when the address is still to be arranged), the booker's answers,
  and the calendar file and a fresh start.

  On Folio's continuous page it replaces everything below the masthead,
  which it draws again in full, so the page keeps its top.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Folio.Components.Masthead
  alias TymeslotWeb.Themes.Shared.ApprovalDisplay
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.CustomAnswers
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.LocationField
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
    assigns =
      assign(assigns,
        pending: ApprovalDisplay.awaiting_approval?(assigns),
        next_day_end: LocalizationHelpers.booking_next_day_end(assigns)
      )

    ~H"""
    <div class="folio-outcome-page booker-card" data-locale={@locale}>
      <Masthead.masthead
        variant={:full}
        theme_tokens={@theme_tokens}
        organizer_profile={@organizer_profile}
        username_context={@username_context}
      />

      <section class="folio-section folio-outcome" data-testid="folio-confirmation">
        <header class="folio-confirmation">
          <span class={["folio-badge", @pending && "folio-badge--pending"]} aria-hidden="true">
            <.icon :if={!@pending} name="hero-check" class="folio-badge__icon" />
            <.icon :if={@pending} name="hero-clock" class="folio-badge__icon" />
          </span>
          <h2 class="folio-title" data-testid="confirmation-heading">{headline(assigns)}</h2>
          <p class="folio-lead">{message(assigns)}</p>
        </header>

        <ApprovalNotice.block
          :if={@pending}
          organizer_name={Profiles.display_name(@organizer_profile)}
          stage={:after}
        />

        <GroupSession.confirmation_line meeting_type={@meeting_type} />

        <section class="folio-details" aria-labelledby="folio-details-heading">
          <h2 id="folio-details-heading" class="folio-eyebrow">
            {dgettext("booking", "Meeting Details")}
          </h2>
          <dl class="folio-details__list">
            <div class="folio-details__row">
              <dt>{dgettext("booking", "Date")}</dt>
              <dd>{LocalizationHelpers.format_date(@selected_date)}</dd>
            </div>
            <div class="folio-details__row">
              <dt>{dgettext("booking", "Time")}</dt>
              <dd>
                {LocalizationHelpers.format_slot_label(@selected_time)}
                <span
                  :if={@next_day_end}
                  class="folio-details__note"
                  data-testid="booking-next-day-end"
                >
                  {@next_day_end}
                </span>
              </dd>
            </div>
            <div class="folio-details__row">
              <dt>{dgettext("booking", "Timezone")}</dt>
              <dd>{Timezones.format(@user_timezone)}</dd>
            </div>
            <div class="folio-details__row">
              <dt>{dgettext("booking", "Duration")}</dt>
              <dd>
                {dgettext("booking", "%{minutes} min",
                  minutes: Offer.duration_minutes(@meeting_type, @duration)
                )}
              </dd>
            </div>
            <div :if={@organizer_profile} class="folio-details__row">
              <dt>{dgettext("booking", "Appointment host")}</dt>
              <dd>{Profiles.display_name(@organizer_profile)}</dd>
            </div>
            <div
              :if={BookingLocation.chosen_display(assigns)}
              class="folio-details__row"
              data-testid="confirmation-location"
            >
              <dt>{dgettext("booking", "Location")}</dt>
              <dd>
                {BookingLocation.chosen_display(assigns)}
                <LocationField.arranged_note
                  :if={BookingLocation.arranged_after_booking?(assigns)}
                  class="folio-details__note"
                />
              </dd>
            </div>
            <div :if={@guest_emails not in [nil, []]} class="folio-details__row">
              <dt>{dgettext("booking", "Guests")}</dt>
              <dd>{Enum.join(@guest_emails, ", ")}</dd>
            </div>
          </dl>
          <p class="folio-muted">
            {dgettext("booking", "Sent to")} <strong>{@email}</strong>
          </p>
        </section>

        <CustomAnswers.custom_answers
          snapshot={@custom_fields_snapshot}
          answers={@custom_field_answers}
        />

        <div class="folio-actions">
          <a
            :if={PathHandlers.calendar_ics_path(assigns)}
            href={PathHandlers.calendar_ics_path(assigns)}
            download
            class="folio-button folio-button--primary"
            data-testid="add-to-calendar"
          >
            <.icon name="hero-calendar-days" class="folio-button__icon" />
            {if @pending,
              do: dgettext("booking", "Add tentative hold to calendar"),
              else: dgettext("booking", "Add to calendar")}
          </a>
          <button
            type="button"
            class="folio-button folio-button--quiet"
            phx-click="schedule_another"
            phx-target={@myself}
            data-testid="schedule-another"
            data-intent="restart"
          >
            {dpgettext("booking_voice", "folio", "Book another session")}
          </button>
        </div>

        <p class="folio-muted folio-confirmation__help">
          {if @pending,
            do:
              dgettext("booking", "Changed your mind? Your request email has a link to withdraw it."),
            else: dgettext("booking", "Need to make changes? Check your email for reschedule options")}
        </p>
      </section>
    </div>
    """
  end

  # Which outcome applies is ConfirmationText's decision (a held request is
  # never announced as confirmed); the words are Folio's, in its personal
  # voice: the visitor by first name, the meeting by its day and date, so
  # a session weeks away is never mistaken for this week's.
  # The held line names nobody: the shared held sentence under it starts
  # with the visitor's name. With no name to say, the day alone.
  defp headline(assigns) do
    name = first_name(assigns[:name])
    weekday = weekday(assigns[:selected_date])
    date = LocalizationHelpers.format_date(assigns[:selected_date])

    case {ConfirmationText.status(assigns), name} do
      {:held, _name} ->
        dpgettext("booking_voice", "folio", "Thank you. I'll reply to your request soon.")

      {:rescheduled, ""} ->
        dpgettext("booking_voice", "folio", "See you on %{weekday} %{date} instead",
          weekday: weekday,
          date: date
        )

      {:rescheduled, name} ->
        dpgettext("booking_voice", "folio", "See you on %{weekday} %{date} instead, %{name}",
          weekday: weekday,
          date: date,
          name: name
        )

      {:confirmed, ""} ->
        dpgettext("booking_voice", "folio", "See you on %{weekday} %{date}",
          weekday: weekday,
          date: date
        )

      {:confirmed, name} ->
        dpgettext("booking_voice", "folio", "See you on %{weekday} %{date}, %{name}",
          weekday: weekday,
          date: date,
          name: name
        )
    end
  end

  defp first_name(name) when is_binary(name) do
    case String.split(String.trim(name), ~r/\s+/, parts: 2) do
      [first | _rest] when first != "" -> first
      _blank -> ""
    end
  end

  defp first_name(_no_name), do: ""

  defp weekday(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, day} -> LocalizationHelpers.mid_sentence_weekday(Date.day_of_week(day))
      {:error, _invalid} -> date
    end
  end

  defp weekday(_no_date), do: ""

  defp message(assigns) do
    case ConfirmationText.status(assigns) do
      :held ->
        ConfirmationText.held_message(assigns[:name], assigns[:organizer_profile], :folio)

      _confirmed_or_rescheduled ->
        dgettext("booking", "%{name}, your meeting %{organizer} is confirmed",
          name: assigns[:name],
          organizer: ConfirmationText.organizer_fragment(assigns[:organizer_profile], :folio)
        )
    end
  end
end
