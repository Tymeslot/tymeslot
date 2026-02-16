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
          <div class="flex-1 flex items-center justify-center px-2 sm:px-4 py-2 md:py-4 lg:py-8">
            <div class="w-full max-w-4xl lg:max-w-6xl">
              <.glass_morphism_card>
                <div class="p-3 md:p-6 lg:p-8">
                  <div class="flex flex-col lg:flex-row items-center gap-6 lg:gap-12">
                    <!-- Success Icon on left side -->
                    <div class="flex-shrink-0">
                      <div class="relative">
                        <div class="confirmation-badge w-24 h-24 sm:w-28 sm:h-28 md:w-32 md:h-32 rounded-full flex items-center justify-center">
                          <svg
                            class="w-12 h-12 sm:w-14 sm:h-14 md:w-16 md:h-16 text-white"
                            fill="none"
                            stroke="currentColor"
                            stroke-width="3"
                            viewBox="0 0 24 24"
                          >
                            <path stroke-linecap="round" stroke-linejoin="round" d="M5 13l4 4L19 7" />
                          </svg>
                        </div>
                        <div class="confirmation-badge-dot absolute -bottom-1 -right-1 w-8 h-8 sm:w-10 sm:h-10 rounded-full flex items-center justify-center">
                          <svg
                            class="w-4 h-4 sm:w-5 sm:h-5 text-white"
                            fill="currentColor"
                            viewBox="0 0 20 20"
                          >
                            <path d="M10 2a6 6 0 00-6 6v3.586l-.707.707A1 1 0 004 14h12a1 1 0 00.707-1.707L16 11.586V8a6 6 0 00-6-6zM10 18a3 3 0 01-3-3h6a3 3 0 01-3 3z" />
                          </svg>
                        </div>
                      </div>
                    </div>
                    
    <!-- Content on right side -->
                    <div class="flex-1 text-center lg:text-left">
                      <div data-testid="confirmation-heading">
                        <.section_header
                          class="mb-4"
                          title_class="section-header text-xl sm:text-2xl md:text-3xl lg:text-4xl"
                        >
                          <%= if @is_rescheduling do %>
                            {gettext("Meeting Rescheduled!")}
                          <% else %>
                            {gettext("meeting_confirmed")}
                          <% end %>
                        </.section_header>
                      </div>

                      <p class="text-quill-primary text-sm sm:text-base md:text-lg mb-3 sm:mb-4">
                        <%= if @is_rescheduling do %>
                          {gettext("%{name}, your meeting %{organizer} has been rescheduled.", name: @name, organizer: get_organizer_text(@organizer_profile))}
                        <% else %>
                          {gettext("%{name}, your meeting %{organizer} is all set.", name: @name, organizer: get_organizer_text(@organizer_profile))}
                        <% end %>
                      </p>

                      <.meeting_details_card title="">
                        <.booking_details
                          date={@selected_date}
                          time={@selected_time}
                          duration={@duration}
                          timezone={@user_timezone}
                          variant={:compact}
                        />

                        <div class="confirmation-border-top mt-4 pt-4 border-t">
                          <div class="cluster cluster-xs">
                            <div class="confirmation-icon-wrapper w-8 h-8 rounded-full center-content">
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
                              {gettext("Confirmation sent to")}
                              <span class="confirmation-email-link font-semibold">
                                {@email}
                              </span>
                            </p>
                          </div>
                        </div>
                      </.meeting_details_card>

                      <div class="mt-4 sm:mt-6 flex flex-col sm:flex-row gap-2 sm:gap-3 justify-center lg:justify-start">
                        <.action_button
                          phx-click="schedule_another"
                          phx-target={@myself}
                          data-testid="schedule-another"
                          class="inline-block"
                        >
                          {gettext("Schedule Another Meeting")}
                        </.action_button>
                      </div>

                      <p class="confirmation-help-text mt-4 text-xs text-center lg:text-left">
                        {gettext("Need to reschedule? Check your confirmation email.")}
                      </p>
                    </div>
                  </div>
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
