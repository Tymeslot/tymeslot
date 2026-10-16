defmodule TymeslotWeb.Themes.Quill.Meeting.CancelConfirmed do
  @moduledoc """
  Quill theme cancel confirmed component with glassmorphism styling.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

  use TymeslotWeb.Components.CoreComponents

  attr :theme_tokens, :any, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true

  @doc """
  Renders the cancel confirmed page in Quill theme style.
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
        <div class="w-full max-w-md">
          <.glass_morphism_card class="booker-card">
            <div class="p-8">
              <div class="text-center">
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
                      d="M5 13l4 4L19 7"
                    />
                  </svg>
                </div>

                <h1 class="text-3xl font-bold mb-2 meeting-page-title">
                  {dgettext("booking_manage", "Meeting Cancelled")}
                </h1>
                <p class="text-lg mb-8 meeting-page-lead">
                  {dgettext("booking_manage", "Your meeting has been successfully cancelled.")}
                </p>

                <div class="mb-8 p-4 rounded-lg flex items-start gap-3 meeting-page-notice meeting-page-notice--success">
                  <svg
                    class="w-5 h-5 shrink-0 mt-0.5 meeting-page-icon--success"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
                    />
                  </svg>
                  <div class="text-sm meeting-page-muted">
                    <strong>{dgettext(
                      "booking_manage",
                      "Cancellation emails have been sent to all participants."
                    )}</strong>
                  </div>
                </div>

                <div class="space-y-4">
                  <.action_button
                    type="button"
                    phx-click={JS.navigate("/")}
                    variant={:primary}
                    class="w-full"
                  >
                    {dgettext("booking_manage", "Schedule a New Meeting")}
                  </.action_button>
                </div>
              </div>
            </div>
          </.glass_morphism_card>
        </div>
      </div>
    </Wrapper.quill_wrapper>
    """
  end
end
