defmodule TymeslotWeb.Themes.Quill.Meeting.Cancel do
  @moduledoc """
  Quill theme cancel component with glassmorphism styling.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Themes.Shared.Customization.Helpers

  @doc """
  Renders the cancel page in Quill theme style.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.quill_wrapper
      theme_customization={@theme_customization}
      custom_css={generate_custom_css(@theme_customization)}
    >
      <div class="min-h-screen flex items-center justify-center px-4 py-8">
        <div class="w-full max-w-2xl">
          <.glass_morphism_card>
            <div class="p-8">
              <%= if assigns[:meeting_kept] do %>
                <!-- Meeting Kept State -->
                <div class="text-center mb-8">
                  <div class="mx-auto mb-4 w-16 h-16">
                    <svg
                      class="w-16 h-16"
                      style="color: #10b981;"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                      />
                    </svg>
                  </div>

                  <h1
                    class="text-3xl font-bold mb-2"
                    style="color: white; text-shadow: 0 2px 4px rgba(0,0,0,0.1);"
                  >
                    Meeting Confirmed
                  </h1>
                  <p class="text-lg" style="color: rgba(255,255,255,0.9);">
                    Great! Your meeting is still scheduled as planned.
                  </p>
                </div>
                
    <!-- Meeting Details Card -->
                <div
                  class="glass-morphism-card mb-8"
                  style="background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.15);"
                >
                  <div class="p-6">
                    <div class="flex items-center justify-between mb-4">
                      <h3 class="text-lg font-semibold" style="color: rgba(255,255,255,0.95);">
                        Meeting Details
                      </h3>
                      <span
                        class="px-3 py-1 rounded-full text-sm font-medium"
                        style="background: var(--theme-primary); color: white;"
                      >
                        {@meeting.duration} min
                      </span>
                    </div>

                    <div class="space-y-4">
                      <!-- Date Row -->
                      <div class="flex items-center gap-4">
                        <div
                          class="w-10 h-10 rounded-lg flex items-center justify-center"
                          style="background: rgba(255,255,255,0.1);"
                        >
                          <span class="text-xl">📅</span>
                        </div>
                        <div class="flex-1">
                          <div class="font-medium" style="color: rgba(255,255,255,0.95);">
                            {Calendar.strftime(@meeting.start_time, "%B %d, %Y")}
                          </div>
                          <div class="text-sm" style="color: rgba(255,255,255,0.6);">Date</div>
                        </div>
                      </div>
                      
    <!-- Time Row -->
                      <div class="flex items-center gap-4">
                        <div
                          class="w-10 h-10 rounded-lg flex items-center justify-center"
                          style="background: rgba(255,255,255,0.1);"
                        >
                          <span class="text-xl">🕐</span>
                        </div>
                        <div class="flex-1">
                          <div class="font-medium" style="color: rgba(255,255,255,0.95);">
                            {Calendar.strftime(@meeting.start_time, "%I:%M %p")}
                          </div>
                          <div class="text-sm" style="color: rgba(255,255,255,0.6);">
                            {@meeting.attendee_timezone}
                          </div>
                        </div>
                      </div>
                      
    <!-- Organizer Row -->
                      <div
                        class="flex items-center gap-4 pt-4"
                        style="border-top: 1px solid rgba(255,255,255,0.1);"
                      >
                        <div
                          class="w-10 h-10 rounded-lg flex items-center justify-center"
                          style="background: rgba(255,255,255,0.1);"
                        >
                          <span class="text-xl">👤</span>
                        </div>
                        <div class="flex-1">
                          <div class="text-sm" style="color: rgba(255,255,255,0.6);">
                            Meeting with
                          </div>
                          <div class="font-medium" style="color: var(--theme-primary);">
                            {@meeting.organizer_name}
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
                
    <!-- Success Message -->
                <div class="text-center">
                  <p class="mb-6" style="color: rgba(255,255,255,0.85);">
                    We look forward to seeing you at the scheduled time.
                  </p>

                  <.action_button type="button" phx-click={JS.navigate("/")} variant={:primary}>
                    Done
                  </.action_button>
                </div>
              <% else %>
                <!-- Cancel State -->
                <div class="text-center mb-8">
                  <div class="mx-auto mb-4 w-16 h-16">
                    <svg
                      class="w-16 h-16"
                      style="color: #ef4444;"
                      fill="none"
                      stroke="currentColor"
                      viewBox="0 0 24 24"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M6 18L18 6M6 6l12 12"
                      />
                    </svg>
                  </div>

                  <h1
                    class="text-3xl font-bold mb-2"
                    style="color: white; text-shadow: 0 2px 4px rgba(0,0,0,0.1);"
                  >
                    Cancel Appointment
                  </h1>
                  <p class="text-lg" style="color: rgba(255,255,255,0.9);">
                    Are you sure you want to cancel this appointment?
                  </p>
                </div>
                
    <!-- Meeting Details Card -->
                <div
                  class="glass-morphism-card mb-8"
                  style="background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.15);"
                >
                  <div class="p-6">
                    <div class="flex items-center justify-between mb-4">
                      <h3 class="text-lg font-semibold" style="color: rgba(255,255,255,0.95);">
                        Meeting Details
                      </h3>
                      <span
                        class="px-3 py-1 rounded-full text-sm font-medium"
                        style="background: var(--theme-primary); color: white;"
                      >
                        {@meeting.duration} min
                      </span>
                    </div>

                    <div class="space-y-4">
                      <!-- Date Row -->
                      <div class="flex items-center gap-4">
                        <div
                          class="w-10 h-10 rounded-lg flex items-center justify-center"
                          style="background: rgba(255,255,255,0.1);"
                        >
                          <span class="text-xl">📅</span>
                        </div>
                        <div class="flex-1">
                          <div class="font-medium" style="color: rgba(255,255,255,0.95);">
                            {Calendar.strftime(@meeting.start_time, "%B %d, %Y")}
                          </div>
                          <div class="text-sm" style="color: rgba(255,255,255,0.6);">Date</div>
                        </div>
                      </div>
                      
    <!-- Time Row -->
                      <div class="flex items-center gap-4">
                        <div
                          class="w-10 h-10 rounded-lg flex items-center justify-center"
                          style="background: rgba(255,255,255,0.1);"
                        >
                          <span class="text-xl">🕐</span>
                        </div>
                        <div class="flex-1">
                          <div class="font-medium" style="color: rgba(255,255,255,0.95);">
                            {Calendar.strftime(@meeting.start_time, "%I:%M %p")}
                          </div>
                          <div class="text-sm" style="color: rgba(255,255,255,0.6);">
                            {@meeting.attendee_timezone}
                          </div>
                        </div>
                      </div>
                      
    <!-- Organizer Row -->
                      <div
                        class="flex items-center gap-4 pt-4"
                        style="border-top: 1px solid rgba(255,255,255,0.1);"
                      >
                        <div
                          class="w-10 h-10 rounded-lg flex items-center justify-center"
                          style="background: rgba(255,255,255,0.1);"
                        >
                          <span class="text-xl">👤</span>
                        </div>
                        <div class="flex-1">
                          <div class="text-sm" style="color: rgba(255,255,255,0.6);">
                            Meeting with
                          </div>
                          <div class="font-medium" style="color: var(--theme-primary);">
                            {@meeting.organizer_name}
                          </div>
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
                
    <!-- Warning Message -->
                <div
                  class="mb-6 p-4 rounded-lg flex items-start gap-3"
                  style="background: rgba(239, 68, 68, 0.1); border: 1px solid rgba(239, 68, 68, 0.2);"
                >
                  <svg
                    class="w-5 h-5 flex-shrink-0 mt-0.5"
                    style="color: #ef4444;"
                    fill="currentColor"
                    viewBox="0 0 20 20"
                  >
                    <path
                      fill-rule="evenodd"
                      d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
                      clip-rule="evenodd"
                    />
                  </svg>
                  <div class="text-sm" style="color: rgba(255,255,255,0.85);">
                    A cancellation email will be sent to all participants
                  </div>
                </div>
                
    <!-- Action Buttons -->
                <div class="flex gap-4">
                  <.loading_button
                    type="button"
                    phx-click="cancel_meeting"
                    loading={@loading}
                    loading_text="Cancelling..."
                    variant={:danger}
                    class="flex-1"
                  >
                    Yes, Cancel Meeting
                  </.loading_button>

                  <.action_button
                    type="button"
                    phx-click="keep_meeting"
                    variant={:secondary}
                    class="flex-1"
                  >
                    Keep Meeting
                  </.action_button>
                </div>
              <% end %>
            </div>
          </.glass_morphism_card>
        </div>
      </div>
    </Wrapper.quill_wrapper>
    """
  end
end
