defmodule TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent do
  @moduledoc """
  Quill theme component for the confirmation/thank you step.
  Features glassmorphism design with elegant transparency effects.
  """
  use TymeslotWeb, :live_component

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Components.MeetingComponents

  @impl true
  def update(assigns, socket) do
    # Filter out reserved assigns that can't be set directly
    filtered_assigns = Map.drop(assigns, [:flash, :socket])
    {:ok, assign(socket, filtered_assigns)}
  end

  @impl true
  def handle_event("schedule_another", _params, socket) do
    send(self(), {:step_event, :confirmation, :schedule_another, nil})
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_layout
        show_steps={true}
        current_step={4}
        duration={@duration}
        username_context={@username_context}
      >
        <div class="container flex-1 flex flex-col">
          <div class="flex-1 flex items-center justify-center px-2 sm:px-4 py-2 md:py-4 lg:py-8">
            <div class="w-full max-w-4xl lg:max-w-6xl">
              <.glass_morphism_card>
                <div class="p-3 md:p-6 lg:p-8">
                  <div class="flex flex-col lg:flex-row items-center gap-6 lg:gap-12">
                    <!-- Success Icon on left side -->
                    <div class="flex-shrink-0">
                      <div class="relative">
                        <div
                          class="w-24 h-24 sm:w-28 sm:h-28 md:w-32 md:h-32 rounded-full flex items-center justify-center"
                          style="background: linear-gradient(135deg, var(--theme-primary) 0%, var(--theme-primary-hover) 100%); box-shadow: 0 12px 32px rgba(6, 182, 212, 0.3);"
                        >
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
                        <div
                          class="absolute -bottom-1 -right-1 w-8 h-8 sm:w-10 sm:h-10 rounded-full flex items-center justify-center"
                          style="background: #10b981; box-shadow: 0 4px 12px rgba(16, 185, 129, 0.4);"
                        >
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
                      <.section_header class="text-xl sm:text-2xl md:text-3xl lg:text-4xl">
                        <%= if @is_rescheduling do %>
                          Meeting Rescheduled!
                        <% else %>
                          Meeting Confirmed!
                        <% end %>
                      </.section_header>

                      <p
                        class="text-sm sm:text-base md:text-lg mb-3 sm:mb-4"
                        style="color: rgba(255,255,255,0.9);"
                      >
                        {@name}, your meeting{get_organizer_text(@organizer_profile)} {if @is_rescheduling,
                          do: "has been rescheduled",
                          else: "is all set"}.
                      </p>

                      <.meeting_details_card title="">
                        <.booking_details
                          date={@selected_date}
                          time={@selected_time}
                          duration={@duration}
                          timezone={@user_timezone}
                          variant={:compact}
                        />

                        <div
                          class="mt-4 pt-4 border-t"
                          style="border-color: rgba(255, 255, 255, 0.2);"
                        >
                          <div class="flex items-center gap-2">
                            <div
                              class="w-8 h-8 rounded-full flex items-center justify-center"
                              style="background: rgba(6, 182, 212, 0.2);"
                            >
                              <svg
                                class="w-4 h-4"
                                style="color: var(--theme-primary);"
                                fill="currentColor"
                                viewBox="0 0 20 20"
                              >
                                <path d="M2.003 5.884L10 9.882l7.997-3.998A2 2 0 0016 4H4a2 2 0 00-1.997 1.884z" />
                                <path d="M18 8.118l-8 4-8-4V14a2 2 0 002 2h12a2 2 0 002-2V8.118z" />
                              </svg>
                            </div>
                            <p class="text-sm" style="color: var(--theme-text, #e2e8f0);">
                              Confirmation sent to
                              <span
                                class="font-semibold"
                                style="color: var(--theme-primary, #06b6d4);"
                              >
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
                          class="inline-block"
                        >
                          Schedule Another Meeting
                        </.action_button>
                      </div>

                      <p
                        class="mt-4 text-xs text-center lg:text-left"
                        style="color: rgba(255,255,255,0.7);"
                      >
                        Need to reschedule? Check your confirmation email.
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
    " with #{organizer_profile.user.name || organizer_profile.full_name}"
  end
end
