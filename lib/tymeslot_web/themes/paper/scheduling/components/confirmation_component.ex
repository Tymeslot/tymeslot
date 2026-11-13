defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Paper's confirmation: a check in a success-tinted circle (a clock on the
  warning tint for a request the organiser still has to accept), the
  headline and message, for a group type the line saying the booking is one
  of its spots, the meeting's details in a quiet box (with the day it ends
  on, when that is the next, and a note when the address is still to be
  arranged), where the
  confirmation went, the guest's answers, and the calendar file and a new
  booking. Which status applies is `ConfirmationText`'s; the wording
  of the headline, the message and the fresh start is Paper's own, in its
  neutral voice, which names the organiser and never the guest.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Paper.Components
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
        held: ApprovalDisplay.awaiting_approval?(assigns),
        location: BookingLocation.chosen_display(assigns),
        calendar_path: PathHandlers.calendar_ics_path(assigns),
        minutes: Offer.duration_minutes(assigns.meeting_type, assigns.duration),
        next_day_end: LocalizationHelpers.booking_next_day_end(assigns)
      )

    ~H"""
    <section class="paper-card booker-card" data-locale={@locale} data-testid="paper-confirmation">
      <Components.brand theme_tokens={@theme_tokens} />

      <header class="paper-confirmation__header">
        <div class={["paper-confirmation__badge", @held && "paper-confirmation__badge--pending"]}>
          <.icon :if={!@held} name="hero-check" class="paper-confirmation__icon" />
          <.icon :if={@held} name="hero-clock" class="paper-confirmation__icon" />
        </div>
        <h1 class="paper-title" data-testid="confirmation-heading">{headline(assigns)}</h1>
        <p class="paper-confirmation__message">{message(assigns)}</p>
      </header>

      <ApprovalNotice.block
        :if={@held}
        organizer_name={Profiles.display_name(@organizer_profile)}
        stage={:after}
      />

      <GroupSession.confirmation_line meeting_type={@meeting_type} />

      <div class="paper-confirmation__details">
        <p class="paper-confirmation__meeting">
          <span :if={@meeting_type} class="paper-confirmation__meeting-name">{@meeting_type.name}</span>
          <span class="paper-badge">{dgettext("booking_confirmation", "%{minutes} min",
            minutes: @minutes
          )}</span>
        </p>
        <ul class="paper-facts" role="list">
          <Components.fact icon="hero-calendar">
            {LocalizationHelpers.format_date(@selected_date)}
          </Components.fact>
          <Components.fact icon="hero-clock">
            {LocalizationHelpers.format_slot_label(@selected_time)}, {LocalizationHelpers.format_zone_label(
              @selected_date,
              @selected_time,
              @user_timezone
            )}
          </Components.fact>
          <Components.fact
            :if={@next_day_end}
            icon="hero-moon"
            data-testid="booking-next-day-end"
          >
            {@next_day_end}
          </Components.fact>
          <Components.fact :if={@organizer_profile} icon="hero-user">
            {dgettext("booking_confirmation", "with %{name}",
              name: Profiles.display_name(@organizer_profile)
            )}
          </Components.fact>
          <Components.fact :if={@location} icon="hero-map-pin" data-testid="confirmation-location">
            {@location}
          </Components.fact>
          <Components.fact :if={@guest_emails not in [nil, []]} icon="hero-user-group">
            {Enum.join(@guest_emails, ", ")}
          </Components.fact>
        </ul>
        <LocationField.arranged_note
          :if={@location && BookingLocation.arranged_after_booking?(assigns)}
          class="paper-confirmation__note"
        />
      </div>

      <p class="paper-confirmation__sent">
        <.icon name="hero-envelope" class="paper-confirmation__sent-icon" />
        <span>{dgettext("booking_confirmation", "Sent to")} <strong>{@email}</strong></span>
      </p>

      <CustomAnswers.custom_answers
        snapshot={@custom_fields_snapshot}
        answers={@custom_field_answers}
      />

      <div class="paper-actions paper-actions--center paper-confirmation__actions">
        <a
          :if={@calendar_path}
          href={@calendar_path}
          download
          class="paper-button paper-button--primary"
          data-testid="add-to-calendar"
        >
          <.icon name="hero-calendar-days" class="paper-button__icon" />
          {if @held,
            do: dgettext("booking_confirmation", "Add tentative hold to calendar"),
            else: dgettext("booking_confirmation", "Add to calendar")}
        </a>
        <button
          type="button"
          class="paper-button paper-button--quiet"
          phx-click="schedule_another"
          phx-target={@myself}
          data-testid="schedule-another"
          data-intent="restart"
        >
          {dpgettext("booking_voice", "paper", "Book another meeting")}
        </button>
      </div>

      <p class="paper-confirmation__help">
        {if @held,
          do:
            dgettext(
              "booking_confirmation",
              "Changed your mind? Your request email has a link to withdraw it."
            ),
          else:
            dgettext(
              "booking_confirmation",
              "Need to make changes? Check your email for reschedule options"
            )}
      </p>
    </section>
    """
  end

  defp headline(assigns) do
    case ConfirmationText.status(assigns) do
      :held -> dpgettext("booking_voice", "paper", "Request sent")
      :rescheduled -> dpgettext("booking_voice", "paper", "Meeting rescheduled")
      :confirmed -> dgettext("booking_confirmation", "Booking confirmed")
    end
  end

  # Paper addresses nobody: the message names the organiser, never the guest,
  # and a profile with no name to give drops the organiser too.
  defp message(assigns) do
    case ConfirmationText.status(assigns) do
      :held ->
        ConfirmationText.held_message(assigns[:name], assigns[:organizer_profile], :paper)

      status ->
        meeting_message(status, Profiles.display_name(assigns[:organizer_profile]))
    end
  end

  defp meeting_message(:rescheduled, organizer) when is_binary(organizer),
    do:
      dpgettext("booking_voice", "paper", "Your meeting with %{organizer} has been rescheduled.",
        organizer: organizer
      )

  defp meeting_message(:rescheduled, _no_organizer),
    do: dpgettext("booking_voice", "paper", "Your meeting has been rescheduled.")

  defp meeting_message(:confirmed, organizer) when is_binary(organizer),
    do:
      dpgettext("booking_voice", "paper", "Your meeting with %{organizer} is confirmed.",
        organizer: organizer
      )

  defp meeting_message(:confirmed, _no_organizer),
    do: dpgettext("booking_voice", "paper", "Your meeting is confirmed.")
end
