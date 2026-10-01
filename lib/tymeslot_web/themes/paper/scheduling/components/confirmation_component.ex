defmodule TymeslotWeb.Themes.Paper.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Paper's confirmation: a check in a success-tinted circle (a clock on the
  warning tint for a request the organiser still has to accept), the
  headline and message, the meeting's details in a quiet box, where the
  confirmation went, the guest's answers, and the calendar file and a new
  booking. Which status applies is `ConfirmationText`'s; only the wording
  of the headline is Paper's.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Availability.Offer
  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Paper.Components
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
    assigns =
      assign(assigns,
        held: ApprovalDisplay.awaiting_approval?(assigns),
        location: BookingLocation.chosen_display(assigns),
        calendar_path: PathHandlers.calendar_ics_path(assigns),
        minutes: Offer.duration_minutes(assigns.meeting_type, assigns.duration)
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

      <div class="paper-confirmation__details">
        <p class="paper-confirmation__meeting">
          <span :if={@meeting_type} class="paper-confirmation__meeting-name">{@meeting_type.name}</span>
          <span class="paper-badge">{dgettext("booking", "%{minutes} min", minutes: @minutes)}</span>
        </p>
        <ul class="paper-facts" role="list">
          <Components.fact icon="hero-calendar">
            {LocalizationHelpers.format_date(@selected_date)}
          </Components.fact>
          <Components.fact icon="hero-clock">
            {LocalizationHelpers.format_slot_label(@selected_time)}, {Timezones.format(@user_timezone)}
          </Components.fact>
          <Components.fact :if={@organizer_profile} icon="hero-user">
            {dgettext("booking", "with %{name}", name: Profiles.display_name(@organizer_profile))}
          </Components.fact>
          <Components.fact :if={@location} icon="hero-map-pin" data-testid="confirmation-location">
            {@location}
          </Components.fact>
          <Components.fact :if={@guest_emails not in [nil, []]} icon="hero-user-group">
            {Enum.join(@guest_emails, ", ")}
          </Components.fact>
        </ul>
      </div>

      <p class="paper-confirmation__sent">
        <.icon name="hero-envelope-mini" class="paper-confirmation__sent-icon" />
        <span>{dgettext("booking", "Sent to")} <strong>{@email}</strong></span>
      </p>

      <CustomAnswers.custom_answers
        snapshot={@custom_fields_snapshot}
        answers={@custom_field_answers}
      />

      <div class="paper-actions paper-actions--center">
        <a
          :if={@calendar_path}
          href={@calendar_path}
          download
          class="paper-button paper-button--secondary"
          data-testid="add-to-calendar"
        >
          <.icon name="hero-calendar-days-mini" class="paper-button__icon" />
          {if @held,
            do: dgettext("booking", "Add tentative hold to calendar"),
            else: dgettext("booking", "Add to calendar")}
        </a>
        <button
          type="button"
          class="paper-button paper-button--primary"
          phx-click="schedule_another"
          phx-target={@myself}
          data-testid="schedule-another"
        >
          {dgettext("booking", "Schedule Another Meeting")}
        </button>
      </div>

      <p class="paper-confirmation__help">
        {if @held,
          do: dgettext("booking", "Changed your mind? Your request email has a link to withdraw it."),
          else: dgettext("booking", "Need to make changes? Check your email for reschedule options")}
      </p>
    </section>
    """
  end

  defp headline(assigns) do
    case ConfirmationText.status(assigns) do
      :held -> dgettext("booking", "Request sent!")
      :rescheduled -> dgettext("booking", "Meeting Rescheduled!")
      :confirmed -> dgettext("booking", "Booking confirmed")
    end
  end

  defp message(assigns) do
    case ConfirmationText.status(assigns) do
      :held ->
        ConfirmationText.held_message(assigns[:name], assigns[:organizer_profile])

      :rescheduled ->
        dgettext("booking", "%{name}, your meeting %{organizer} has been rescheduled.",
          name: assigns[:name],
          organizer: ConfirmationText.organizer_fragment(assigns[:organizer_profile])
        )

      :confirmed ->
        dgettext("booking", "%{name}, your meeting %{organizer} is confirmed",
          name: assigns[:name],
          organizer: ConfirmationText.organizer_fragment(assigns[:organizer_profile])
        )
    end
  end
end
