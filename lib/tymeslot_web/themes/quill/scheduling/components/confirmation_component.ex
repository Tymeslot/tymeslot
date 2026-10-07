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
  alias TymeslotWeb.Themes.Shared.ConfirmationText
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.PathHandlers
  alias TymeslotWeb.Themes.Shared.StepEvents

  import TymeslotWeb.Components.CoreComponents

  @impl Phoenix.LiveComponent
  defdelegate update(assigns, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  defdelegate handle_event(event, params, socket), to: StepEvents

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="container quill-container flex-1" data-locale={@locale}>
      <.page_layout
        show_steps={true}
        current_step={4}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="stack">
          <div class="confirmation-outer flex-1 flex items-center justify-center">
            <div class="w-full confirmation-container">
              <.glass_morphism_card class="booker-card">
                <div class="confirmation-content">
                  <div class="confirmation-heading-row flex items-center">
                    <div class="shrink-0">
                      <div class="relative">
                        <div class={[
                          "confirmation-badge rounded-full flex items-center justify-center",
                          ApprovalDisplay.awaiting_approval?(assigns) && "confirmation-badge--pending"
                        ]}>
                          <svg
                            :if={!ApprovalDisplay.awaiting_approval?(assigns)}
                            class="confirmation-badge-icon text-white"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="3"
                            viewBox="0 0 24 24"
                          >
                            <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
                          </svg>
                          <svg
                            :if={ApprovalDisplay.awaiting_approval?(assigns)}
                            class="confirmation-badge-icon text-white"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="3"
                            viewBox="0 0 24 24"
                          >
                            <path
                              stroke-linecap="round"
                              stroke-linejoin="round"
                              d="M12 6v6h4.5m4.5 0a9 9 0 11-18 0 9 9 0 0118 0z"
                            />
                          </svg>
                        </div>
                        <div class={[
                          "confirmation-badge-dot absolute rounded-full flex items-center justify-center",
                          ApprovalDisplay.awaiting_approval?(assigns) &&
                            "confirmation-badge-dot--pending"
                        ]}>
                          <svg
                            class="confirmation-badge-dot-icon text-white"
                            fill="currentColor"
                            viewBox="0 0 20 20"
                          >
                            <path d="M10 2a6 6 0 00-6 6v3.586l-.707.707A1 1 0 004 14h12a1 1 0 00.707-1.707L16 11.586V8a6 6 0 00-6-6zM10 18a3 3 0 01-3-3h6a3 3 0 01-3 3z" />
                          </svg>
                        </div>
                      </div>
                    </div>
                    <div class="flex-1 min-w-0" data-testid="confirmation-heading">
                      <.section_header
                        class="mb-1"
                        title_class="section-header confirmation-title"
                      >
                        {headline(assigns)}
                      </.section_header>
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

                  <.meeting_details_card title="">
                    <.booking_details
                      date={@selected_date}
                      time={@selected_time}
                      duration={BookingText.duration_label(assigns)}
                      timezone={@user_timezone}
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
                    </div>

                    <div class="confirmation-border-top mt-3 pt-3 border-t">
                      <div class="confirmation-email-row">
                        <div class="confirmation-icon-wrapper rounded-full">
                          <svg
                            class="confirmation-email-link w-4 h-4"
                            fill="currentColor"
                            viewBox="0 0 20 20"
                          >
                            <path d="M2.003 5.884L10 9.882l7.997-3.998A2 2 0 0016 4H4a2 2 0 00-1.997 1.884z" />
                            <path d="M18 8.118l-8 4-8-4V14a2 2 0 002 2h12a2 2 0 002-2V8.118z" />
                          </svg>
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
                          <svg
                            class="confirmation-email-link w-4 h-4"
                            fill="currentColor"
                            viewBox="0 0 20 20"
                          >
                            <path d="M9 6a3 3 0 11-6 0 3 3 0 016 0zM17 6a3 3 0 11-6 0 3 3 0 016 0zM12.93 17c.046-.327.07-.66.07-1a6.97 6.97 0 00-1.5-4.33A5 5 0 0119 16v1h-6.07zM6 11a5 5 0 015 5v1H1v-1a5 5 0 015-5z" />
                          </svg>
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
        ConfirmationText.held_message(assigns[:name], assigns[:organizer_profile])

      :rescheduled ->
        dgettext("booking", "%{name}, your meeting %{organizer} has been rescheduled.",
          name: assigns[:name],
          organizer: ConfirmationText.organizer_fragment(assigns[:organizer_profile])
        )

      :confirmed ->
        dgettext("booking", "%{name}, your meeting %{organizer} is all set.",
          name: assigns[:name],
          organizer: ConfirmationText.organizer_fragment(assigns[:organizer_profile])
        )
    end
  end
end
