defmodule TymeslotWeb.Themes.Quill.Meeting.Reschedule do
  @moduledoc """
  Quill theme reschedule component with glassmorphism styling.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Themes.Shared.Customization.Helpers

  @doc """
  Renders the reschedule page in Quill theme style.
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
              <!-- Header -->
              <div class="text-center mb-8">
                <div class="mx-auto mb-4 w-12 h-12">
                  <svg
                    class="w-12 h-12"
                    style="color: var(--theme-primary);"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003 8.003 0 01-15.357-2m15.357 2H15"
                    />
                  </svg>
                </div>

                <h1
                  class="text-3xl font-bold mb-2"
                  style="color: white; text-shadow: 0 2px 4px rgba(0,0,0,0.1);"
                >
                  Reschedule Appointment
                </h1>
                <p class="text-lg" style="color: rgba(255,255,255,0.9);">
                  Select a new time for your meeting
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
                      Current Meeting
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
                        <div class="text-sm" style="color: rgba(255,255,255,0.6);">Meeting with</div>
                        <div class="font-medium" style="color: var(--theme-primary);">
                          {@meeting.organizer_name}
                        </div>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
              
    <!-- Action Section -->
              <div class="text-center">
                <p class="mb-6" style="color: rgba(255,255,255,0.85);">
                  Ready to pick a new time? Let's find one that works better for you.
                </p>

                <.action_button
                  type="button"
                  phx-click={JS.navigate(get_calendar_url(assigns))}
                  variant={:primary}
                >
                  <span>Choose New Time</span>
                  <svg
                    class="ml-2 h-5 w-5 flex-shrink-0"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M8 7V3m8 4V3m-9 8h10M5 21h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v12a2 2 0 002 2z"
                    />
                  </svg>
                </.action_button>
              </div>
            </div>
          </.glass_morphism_card>
        </div>
      </div>
    </Wrapper.quill_wrapper>
    """
  end

  defp get_calendar_url(assigns) do
    username =
      case assigns[:organizer_profile] do
        %{username: username} when is_binary(username) -> username
        _ -> "schedule"
      end

    "/#{username}"
  end
end
