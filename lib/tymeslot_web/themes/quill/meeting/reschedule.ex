defmodule TymeslotWeb.Themes.Quill.Meeting.Reschedule do
  @moduledoc """
  Quill theme reschedule component with glassmorphism styling.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.PathHandlers

  import TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Themes.Shared.Components.MeetingDetails, only: [meeting_detail_rows: 1]

  attr :theme_customization, :map, required: true
  attr :custom_css, :string, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true
  attr :meeting, :map, required: true
  attr :organizer_profile, :map, default: nil

  @doc """
  Renders the reschedule page in Quill theme style.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.quill_wrapper
      theme_customization={@theme_customization}
      custom_css={@custom_css}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="min-h-screen flex items-center justify-center px-4 py-8">
        <div class="w-full max-w-2xl">
          <.glass_morphism_card>
            <div class="p-8">
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
                  {gettext("Reschedule Appointment")}
                </h1>
                <p class="text-lg" style="color: rgba(255,255,255,0.9);">
                  {gettext("Select a new time for your meeting")}
                </p>
              </div>

              <div
                class="glass-morphism-card mb-8"
                style="background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.15);"
              >
                <div class="p-6">
                  <div class="flex items-center justify-between mb-4">
                    <h3 class="text-lg font-semibold" style="color: rgba(255,255,255,0.95);">
                      {gettext("Current Meeting")}
                    </h3>
                    <span
                      class="px-3 py-1 rounded-full text-sm font-medium"
                      style="background: var(--theme-primary); color: white;"
                    >
                      {@meeting.duration} min
                    </span>
                  </div>

                  <.meeting_detail_rows
                    date={LocaleFormat.format_date(@meeting.start_time, @locale)}
                    time={LocaleFormat.format_time(@meeting.start_time, @locale)}
                    timezone={@meeting.attendee_timezone}
                    organizer_name={@meeting.organizer_name}
                  />
                </div>
              </div>

              <div class="text-center">
                <p class="mb-6" style="color: rgba(255,255,255,0.85);">
                  {gettext("Ready to pick a new time? Let's find one that works better for you.")}
                </p>

                <.action_button
                  type="button"
                  phx-click={JS.navigate(PathHandlers.organizer_scheduling_path(assigns))}
                  variant={:primary}
                >
                  <span>{gettext("Choose New Time")}</span>
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
end
