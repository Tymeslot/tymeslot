defmodule TymeslotWeb.Themes.Folio.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Folio's confirmation step: the slim masthead, the outcome (confirmed,
  rescheduled, or a request awaiting the organiser's approval) with its
  badge, the meeting's details, the booker's answers, and the calendar file
  and a fresh start.
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
    assigns = assign(assigns, :pending, ApprovalDisplay.awaiting_approval?(assigns))

    ~H"""
    <section class="folio-card folio-card--confirmation booker-card" data-locale={@locale}>
      <Masthead.masthead
        variant={:slim}
        theme_tokens={@theme_tokens}
        organizer_profile={@organizer_profile}
        username_context={@username_context}
        meeting_label={Masthead.meeting_label(assigns)}
      />

      <div class="folio-card__body">
        <header class="folio-confirmation">
          <span class={["folio-badge", @pending && "folio-badge--pending"]} aria-hidden="true">
            <.icon :if={!@pending} name="hero-check" class="folio-badge__icon" />
            <.icon :if={@pending} name="hero-clock" class="folio-badge__icon" />
          </span>
          <h1 class="folio-title" data-testid="confirmation-heading">{headline(assigns)}</h1>
          <p class="folio-lead">{message(assigns)}</p>
        </header>

        <ApprovalNotice.block
          :if={@pending}
          organizer_name={Profiles.display_name(@organizer_profile)}
          stage={:after}
        />

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
              <dd>{LocalizationHelpers.format_slot_label(@selected_time)}</dd>
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
              <dd>{BookingLocation.chosen_display(assigns)}</dd>
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
            class="folio-button folio-button--secondary"
            data-testid="add-to-calendar"
          >
            <.icon name="hero-calendar-days" class="folio-button__icon" />
            {if @pending,
              do: dgettext("booking", "Add tentative hold to calendar"),
              else: dgettext("booking", "Add to calendar")}
          </a>
          <button
            type="button"
            class="folio-button folio-button--primary"
            phx-click="schedule_another"
            phx-target={@myself}
            data-testid="schedule-another"
            data-intent="restart"
          >
            {dgettext("booking", "Schedule Another Meeting")}
          </button>
        </div>

        <p class="folio-muted folio-confirmation__help">
          {if @pending,
            do:
              dgettext("booking", "Changed your mind? Your request email has a link to withdraw it."),
            else: dgettext("booking", "Need to make changes? Check your email for reschedule options")}
        </p>
      </div>
    </section>
    """
  end

  # Which outcome applies is ConfirmationText's decision (a held request is
  # never announced as confirmed); only the wording is Folio's.
  defp headline(assigns) do
    case ConfirmationText.status(assigns) do
      :held -> dgettext("booking", "Request sent!")
      :rescheduled -> dgettext("booking", "Successfully Rescheduled!")
      :confirmed -> dgettext("booking", "You're All Set!")
    end
  end

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
