defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Quill theme component for the confirmation/thank you step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Timezones
  alias TymeslotWeb.Themes.Shared.ApprovalDisplay
  alias TymeslotWeb.Themes.Shared.BookingLocation
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.CustomAnswers
  alias TymeslotWeb.Themes.Shared.Components.GroupSession
  alias TymeslotWeb.Themes.Shared.Components.LocationField
  alias TymeslotWeb.Themes.Shared.Components.MeetingPrice
  alias TymeslotWeb.Themes.Shared.ConfirmationText
  alias TymeslotWeb.Themes.Shared.Journey.Runtime
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.PathHandlers
  alias TymeslotWeb.Themes.Shared.StepEvents

  use TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    assigns =
      assign(assigns,
        navigable_steps: Runtime.navigable_steps(assigns),
        step_numbers: Runtime.step_numbers(assigns)
      )

    ~H"""
    <div class="container quill-container flex-1" data-locale={@locale}>
      <.page_layout
        show_steps={true}
        navigable_steps={@navigable_steps}
        step_numbers={@step_numbers}
        current_step={4}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="stack">
          <div class="confirmation-outer flex-1 flex items-center justify-center">
            <div class="w-full confirmation-container">
              <.glass_morphism_card class="booker-card" data-testid="booker-card">
                <div class="confirmation-content">
                  <div class="confirmation-heading-row flex items-center">
                    <div class="shrink-0">
                      <div class="relative">
                        <div class={[
                          "confirmation-badge rounded-full flex items-center justify-center",
                          ApprovalDisplay.awaiting_approval?(assigns) && "confirmation-badge--pending"
                        ]}>
                          <.icon
                            :if={!ApprovalDisplay.awaiting_approval?(assigns)}
                            name="hero-check"
                            class="confirmation-badge-icon text-white stroke-3"
                          />
                          <.icon
                            :if={ApprovalDisplay.awaiting_approval?(assigns)}
                            name="hero-clock"
                            class="confirmation-badge-icon text-white stroke-3"
                          />
                        </div>
                        <div class={[
                          "confirmation-badge-dot absolute rounded-full flex items-center justify-center",
                          ApprovalDisplay.awaiting_approval?(assigns) &&
                            "confirmation-badge-dot--pending"
                        ]}>
                          <.icon name="hero-bell-mini" class="confirmation-badge-dot-icon text-white" />
                        </div>
                      </div>
                    </div>
                    <div class="flex-1 min-w-0" data-testid="confirmation-heading">
                      <h1 class="section-header confirmation-title">
                        {headline(assigns)}
                      </h1>
                      <p class="confirmation-subtitle text-quill-primary">
                        {subtitle(assigns)}
                      </p>
                    </div>
                  </div>

                  <ApprovalNotice.block
                    :if={ApprovalDisplay.awaiting_approval?(assigns)}
                    organizer_name={Profiles.display_name(@organizer_profile)}
                    stage={:after}
                    class="mt-4"
                  />

                  <GroupSession.confirmation_line meeting_type={@meeting_type} class="mt-4" />

                  <.meeting_details_card title="">
                    <.booking_details
                      date={@selected_date}
                      time={@selected_time}
                      duration={BookingText.duration_label(assigns)}
                      timezone={@user_timezone}
                      next_day_end={LocalizationHelpers.booking_next_day_end(assigns)}
                      variant={:compact}
                    />

                    <div
                      :if={BookingLocation.chosen_display(assigns)}
                      class="confirmation-border-top mt-3 pt-3 border-t"
                    >
                      <div class="confirmation-email-row" data-testid="confirmation-location">
                        <div class="confirmation-icon-wrapper rounded-full">
                          <.icon name="hero-map-pin" class="confirmation-email-link w-4 h-4" />
                        </div>
                        <p class="text-sm text-white">
                          {dgettext("booking", "Location")}:
                          <span class="confirmation-email-link font-semibold">
                            {BookingLocation.chosen_display(assigns)}
                          </span>
                        </p>
                      </div>
                      <LocationField.arranged_note :if={
                        BookingLocation.arranged_after_booking?(assigns)
                      } />
                    </div>

                    <div
                      :if={MeetingPrice.paid_price(assigns[:paid_payment], @locale)}
                      class="confirmation-border-top mt-3 pt-3 border-t"
                    >
                      <div class="confirmation-email-row" data-testid="confirmation-paid">
                        <div class="confirmation-icon-wrapper rounded-full">
                          <.icon name="hero-credit-card" class="confirmation-email-link w-4 h-4" />
                        </div>
                        <.paid_line amount={MeetingPrice.paid_price(@paid_payment, @locale)} />
                      </div>
                    </div>

                    <div class="confirmation-border-top mt-3 pt-3 border-t">
                      <div class="confirmation-email-row">
                        <div class="confirmation-icon-wrapper rounded-full">
                          <.icon name="hero-envelope-mini" class="confirmation-email-link w-4 h-4" />
                        </div>
                        <p class="text-sm text-white">
                          {if ApprovalDisplay.awaiting_approval?(assigns),
                            do: dgettext("booking", "Sent to"),
                            else: dgettext("booking", "Confirmation sent to")}
                          <span class="confirmation-email-link font-semibold">
                            {@email}
                          </span>
                        </p>
                      </div>
                    </div>

                    <div
                      :if={@guest_emails not in [nil, []]}
                      class="confirmation-border-top mt-3 pt-3 border-t"
                    >
                      <div class="confirmation-email-row">
                        <div class="confirmation-icon-wrapper rounded-full">
                          <.icon name="hero-users-mini" class="confirmation-email-link w-4 h-4" />
                        </div>
                        <p class="text-sm text-white">
                          {dgettext("booking", "Guests")}:
                          <span class="confirmation-email-link font-semibold">
                            {Enum.join(@guest_emails, ", ")}
                          </span>
                        </p>
                      </div>
                    </div>
                  </.meeting_details_card>

                  <CustomAnswers.custom_answers
                    snapshot={@custom_fields_snapshot}
                    answers={@custom_field_answers}
                  />

                  <div class="confirmation-actions">
                    <a
                      :if={PathHandlers.calendar_ics_path(assigns)}
                      href={PathHandlers.calendar_ics_path(assigns)}
                      download
                      class="action-button action-button--secondary calendar-download-button"
                      data-testid="add-to-calendar"
                    >
                      <.icon name="hero-calendar-days" class="calendar-download-icon" />
                      {if ApprovalDisplay.awaiting_approval?(assigns),
                        do: dgettext("booking", "Add tentative hold to calendar"),
                        else: dgettext("booking", "Add to calendar")}
                    </a>
                    <.action_button
                      phx-click="schedule_another"
                      phx-target={@myself}
                      data-testid="schedule-another"
                      data-intent="restart"
                      class="inline-block"
                    >
                      {dgettext("booking", "Schedule Another Meeting")}
                    </.action_button>
                  </div>

                  <p class="confirmation-help-text mt-3 text-xs">
                    {if ApprovalDisplay.awaiting_approval?(assigns),
                      do:
                        dgettext(
                          "booking",
                          "Changed your mind? Your request email has a link to withdraw it."
                        ),
                      else: dgettext("booking", "Need to reschedule? Check your confirmation email.")}
                  </p>
                </div>
              </.glass_morphism_card>
            </div>
          </div>
        </div>
      </.page_layout>
    </div>
    """
  end

  # ========== MEETING DISPLAY COMPONENTS ==========

  attr :title, :string, default: ""
  slot :inner_block, required: true

  defp meeting_details_card(assigns) do
    ~H"""
    <div class="meeting-details-card">
      <%= if @title && @title != "" do %>
        <h3 class="text-lg font-semibold mb-4 text-purple-900">{@title}</h3>
      <% end %>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :date, :string, required: true
  attr :time, :string, required: true
  attr :duration, :string, required: true, doc: "the formatted duration"
  attr :timezone, :string, required: true
  attr :next_day_end, :string, default: nil, doc: "when the meeting ends on a later day"
  attr :variant, :atom, default: :compact, values: [:compact, :expanded]

  defp booking_details(assigns) do
    grid_class =
      case assigns.variant do
        :expanded -> "booking-details-grid booking-details-grid--expanded"
        _other -> "booking-details-grid"
      end

    assigns =
      assigns
      |> assign(:grid_class, grid_class)
      |> assign_new(:date_label, fn -> dgettext("booking", "Date") end)
      |> assign_new(:time_label, fn -> dgettext("booking", "Time") end)
      |> assign_new(:duration_label, fn -> dgettext("booking", "Duration") end)
      |> assign_new(:timezone_label, fn -> dgettext("booking", "Timezone") end)
      |> assign_new(:formatted_date, fn -> LocalizationHelpers.format_date(assigns.date) end)
      |> assign_new(:formatted_time, fn -> LocalizationHelpers.format_slot_label(assigns.time) end)
      |> assign_new(:formatted_timezone, fn -> Timezones.format(assigns.timezone) end)

    ~H"""
    <div class={@grid_class}>
      <div>
        <p class="booking-detail-label">{@date_label}</p>
        <p class="booking-detail-value">{@formatted_date}</p>
      </div>
      <div>
        <p class="booking-detail-label">{@time_label}</p>
        <p class="booking-detail-value">{@formatted_time}</p>
        <p :if={@next_day_end} class="booking-detail-value" data-testid="booking-next-day-end">
          {@next_day_end}
        </p>
      </div>
      <div>
        <p class="booking-detail-label">{@duration_label}</p>
        <p class="booking-detail-value">{@duration}</p>
      </div>
      <div>
        <p class="booking-detail-label">{@timezone_label}</p>
        <p class="booking-detail-value">{@formatted_timezone}</p>
      </div>
    </div>
    """
  end

  # ========== PRIVATE HELPERS ==========

  # Placeholder for the amount while the paid line is translated: a private-use
  # character no translation contains.
  @amount_marker "\u{E000}"

  # The paid line is one msgid, so a language can put the amount wherever its
  # grammar wants it; the translation is then split around the amount so the
  # amount keeps its own emphasis.
  attr :amount, :string, required: true

  defp paid_line(assigns) do
    {before, rest} = split_paid_line()
    assigns = assign(assigns, before: before, rest: rest)

    ~H"""
    <p class="text-sm text-white">
      {@before}<span class="confirmation-email-link font-semibold">{@amount}</span>{@rest}
    </p>
    """
  end

  defp split_paid_line do
    line = dgettext("booking", "Paid %{amount}", amount: @amount_marker)

    case String.split(line, @amount_marker, parts: 2) do
      [before, rest] -> {before, rest}
      [line] -> {line <> " ", ""}
    end
  end

  # A held request is not a confirmed meeting, and this screen is the last thing
  # an invitee sees before the emails arrive, so the heading changes too, not
  # just a note underneath it. Which status applies is decided in
  # ConfirmationText; only the wording is Quill's.
  defp headline(assigns) do
    case ConfirmationText.status(assigns) do
      :held -> dgettext("booking", "Request sent!")
      :rescheduled -> dgettext("booking", "Meeting Rescheduled!")
      :confirmed -> dgettext("booking", "Meeting Confirmed!")
    end
  end

  defp subtitle(assigns) do
    case ConfirmationText.status(assigns) do
      :held ->
        ConfirmationText.held_message(assigns[:name], assigns[:organizer_profile], :quill)

      :rescheduled ->
        dgettext("booking", "%{name}, your meeting %{organizer} has been rescheduled.",
          name: assigns[:name],
          organizer: ConfirmationText.organizer_fragment(assigns[:organizer_profile], :quill)
        )

      :confirmed ->
        dgettext("booking", "%{name}, your meeting %{organizer} is all set.",
          name: assigns[:name],
          organizer: ConfirmationText.organizer_fragment(assigns[:organizer_profile], :quill)
        )
    end
  end
end
