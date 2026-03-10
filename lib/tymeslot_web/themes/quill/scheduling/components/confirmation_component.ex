defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Quill theme component for the confirmation/thank you step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.MeetingComponents

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("schedule_another", _params, socket) do
    send(self(), {:step_event, :confirmation, :schedule_another, nil})
    {:noreply, socket}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div data-locale={@locale}>
      <.page_layout
        show_steps={true}
        current_step={4}
        slug={@duration}
        username_context={@username_context}
      >
        <div class="container stack flex-1">
          <div class="confirmation-outer flex-1 flex items-center justify-center px-2 sm:px-4 py-2 md:py-4 lg:py-8">
            <div class="w-full max-w-4xl lg:max-w-6xl">
              <.glass_morphism_card>
                <div class="confirmation-content p-3 md:p-6 lg:p-8">
                  <!-- Heading row: badge + title inline -->
                  <div class="confirmation-heading-row flex items-center gap-3 sm:gap-4 lg:gap-6 mb-3 sm:mb-4">
                    <div class="flex-shrink-0">
                      <div class="relative">
                        <div class="confirmation-badge w-14 h-14 sm:w-20 sm:h-20 md:w-24 md:h-24 lg:w-28 lg:h-28 rounded-full flex items-center justify-center">
                          <svg
                            class="w-7 h-7 sm:w-10 sm:h-10 md:w-12 md:h-12 lg:w-14 lg:h-14 text-white"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="3"
                            viewBox="0 0 24 24"
                          >
                            <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
                          </svg>
                        </div>
                        <div class="confirmation-badge-dot absolute -bottom-1 -right-1 w-6 h-6 sm:w-8 sm:h-8 rounded-full flex items-center justify-center">
                          <svg
                            class="w-3 h-3 sm:w-4 sm:h-4 text-white"
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
                        title_class="section-header text-lg sm:text-xl md:text-2xl lg:text-4xl"
                      >
                        <%= if @is_rescheduling do %>
                          {gettext("Meeting Rescheduled!")}
                        <% else %>
                          {gettext("meeting_confirmed")}
                        <% end %>
                      </.section_header>
                      <p class="text-quill-primary text-sm sm:text-base md:text-lg">
                        <%= if @is_rescheduling do %>
                          {gettext("%{name}, your meeting %{organizer} has been rescheduled.", name: @name, organizer: get_organizer_text(@organizer_profile))}
                        <% else %>
                          {gettext("%{name}, your meeting %{organizer} is all set.", name: @name, organizer: get_organizer_text(@organizer_profile))}
                        <% end %>
                      </p>
                    </div>
                  </div>

                  <!-- Details + actions -->
                  <.meeting_details_card title="">
                    <.booking_details
                      date={@selected_date}
                      time={@selected_time}
                      duration={@duration}
                      timezone={@user_timezone}
                      variant={:compact}
                    />

                    <div class="confirmation-border-top mt-3 pt-3 border-t">
                      <div class="cluster cluster-xs">
                        <div class="confirmation-icon-wrapper w-7 h-7 rounded-full center-content">
                          <svg
                            class="confirmation-email-link w-3.5 h-3.5"
                            fill="currentColor"
                            viewBox="0 0 20 20"
                          >
                            <path d="M2.003 5.884L10 9.882l7.997-3.998A2 2 0 0016 4H4a2 2 0 00-1.997 1.884z" />
                            <path d="M18 8.118l-8 4-8-4V14a2 2 0 002 2h12a2 2 0 002-2V8.118z" />
                          </svg>
                        </div>
                        <p class="text-sm text-white">
                          {gettext("Confirmation sent to")}
                          <span class="confirmation-email-link font-semibold">
                            {@email}
                          </span>
                        </p>
                      </div>
                    </div>
                  </.meeting_details_card>

                  <div class="mt-3 sm:mt-4 flex flex-col sm:flex-row gap-2 sm:gap-3">
                    <.action_button
                      phx-click="schedule_another"
                      phx-target={@myself}
                      data-testid="schedule-another"
                      class="inline-block"
                    >
                      {gettext("Schedule Another Meeting")}
                    </.action_button>
                  </div>

                  <p class="confirmation-help-text mt-3 text-xs">
                    {gettext("Need to reschedule? Check your confirmation email.")}
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

  # Helper functions
  defp get_organizer_text(nil), do: ""

  defp get_organizer_text(organizer_profile) do
    gettext("with %{name}", name: organizer_profile.user.name || organizer_profile.full_name)
  end
end
