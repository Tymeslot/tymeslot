defmodule TymeslotWeb.Themes.Quill.Meeting.Cancel do
  @moduledoc """
  Quill theme cancel component with glassmorphism styling.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

  use TymeslotWeb.Components.CoreComponents
  import TymeslotWeb.Themes.Shared.Components.MeetingDetails, only: [meeting_detail_rows: 1]

  attr :theme_tokens, :any, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true
  attr :meeting, :map, required: true
  attr :organizer_profile, :map, default: nil
  attr :loading, :boolean, required: true
  attr :meeting_kept, :boolean, default: false

  @doc """
  Renders the cancel page in Quill theme style.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.quill_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="min-h-screen flex items-center justify-center px-4 py-8">
        <div class="w-full max-w-2xl">
          <.glass_morphism_card class="booker-card">
            <div class="p-8">
              <%= if @meeting_kept do %>
                <div class="text-center mb-8">
                  <div class="mx-auto mb-4 w-16 h-16">
                    <svg
                      class="w-16 h-16 meeting-page-icon--success"
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

                  <h1 class="text-3xl font-bold mb-2 meeting-page-title">
                    {dgettext("booking_manage", "Meeting Confirmed")}
                  </h1>
                  <p class="text-lg meeting-page-lead">
                    {dgettext("booking_manage", "Great! Your meeting is still scheduled as planned.")}
                  </p>
                </div>

                <div class="glass-morphism-card booker-card meeting-page-panel mb-8">
                  <div class="p-6">
                    <div class="flex items-center justify-between mb-4">
                      <h3 class="text-lg font-semibold meeting-page-panel-title">
                        {dgettext("booking_manage", "Meeting Details")}
                      </h3>
                      <span class="px-3 py-1 rounded-full text-sm font-medium meeting-page-duration">
                        {dgettext("booking_manage", "%{minutes} min", minutes: @meeting.duration)}
                      </span>
                    </div>

                    <.meeting_detail_rows
                      start_time={@meeting.start_time}
                      timezone={@meeting.attendee_timezone}
                      organizer_profile={@organizer_profile}
                      locale={@locale}
                      organizer_name={@meeting.organizer_name}
                    />
                  </div>
                </div>

                <div class="text-center">
                  <p class="mb-6 meeting-page-muted">
                    {dgettext(
                      "booking_manage",
                      "We look forward to seeing you at the scheduled time."
                    )}
                  </p>

                  <.action_button type="button" phx-click={JS.navigate("/")} variant={:primary}>
                    {dgettext("booking_manage", "Done")}
                  </.action_button>
                </div>
              <% else %>
                <div class="text-center mb-8">
                  <div class="mx-auto mb-4 w-16 h-16">
                    <svg
                      class="w-16 h-16 meeting-page-icon--danger"
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

                  <h1 class="text-3xl font-bold mb-2 meeting-page-title">
                    {dgettext("booking_manage", "Cancel Appointment")}
                  </h1>
                  <p class="text-lg meeting-page-lead">
                    {dgettext("booking_manage", "Are you sure you want to cancel this appointment?")}
                  </p>
                </div>

                <div class="glass-morphism-card booker-card meeting-page-panel mb-8">
                  <div class="p-6">
                    <div class="flex items-center justify-between mb-4">
                      <h3 class="text-lg font-semibold meeting-page-panel-title">
                        {dgettext("booking_manage", "Meeting Details")}
                      </h3>
                      <span class="px-3 py-1 rounded-full text-sm font-medium meeting-page-duration">
                        {dgettext("booking_manage", "%{minutes} min", minutes: @meeting.duration)}
                      </span>
                    </div>

                    <.meeting_detail_rows
                      start_time={@meeting.start_time}
                      timezone={@meeting.attendee_timezone}
                      organizer_profile={@organizer_profile}
                      locale={@locale}
                      organizer_name={@meeting.organizer_name}
                    />
                  </div>
                </div>

                <div class="mb-6 p-4 rounded-lg flex items-start gap-3 meeting-page-notice meeting-page-notice--danger">
                  <svg
                    class="w-5 h-5 shrink-0 mt-0.5 meeting-page-icon--danger"
                    fill="currentColor"
                    viewBox="0 0 20 20"
                  >
                    <path
                      fill-rule="evenodd"
                      d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
                      clip-rule="evenodd"
                    />
                  </svg>
                  <div class="text-sm meeting-page-muted">
                    {dgettext(
                      "booking_manage",
                      "A cancellation email will be sent to all participants"
                    )}
                  </div>
                </div>

                <div class="flex gap-4">
                  <.loading_button
                    type="button"
                    phx-click="cancel_meeting"
                    loading={@loading}
                    loading_text={dgettext("booking_manage", "Cancelling...")}
                    variant={:danger}
                    data-testid="cancel-meeting"
                    class="flex-1"
                  >
                    {dgettext("booking_manage", "Yes, Cancel Meeting")}
                  </.loading_button>

                  <.action_button
                    type="button"
                    phx-click="keep_meeting"
                    variant={:secondary}
                    data-testid="keep-meeting"
                    disabled={@loading}
                    class="flex-1"
                  >
                    {dgettext("booking_manage", "Keep Meeting")}
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
