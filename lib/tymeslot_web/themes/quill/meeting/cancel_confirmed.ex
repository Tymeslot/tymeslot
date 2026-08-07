defmodule TymeslotWeb.Themes.Quill.Meeting.CancelConfirmed do
  @moduledoc """
  Quill theme cancel confirmed component with glassmorphism styling.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

  import TymeslotWeb.Components.CoreComponents

  attr :theme_customization, :map, required: true
  attr :custom_css, :string, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true

  @doc """
  Renders the cancel confirmed page in Quill theme style.
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
        <div class="w-full max-w-md">
          <.glass_morphism_card>
            <div class="p-8">
              <div class="text-center">
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
                      d="M5 13l4 4L19 7"
                    />
                  </svg>
                </div>

                <h1
                  class="text-3xl font-bold mb-2"
                  style="color: white; text-shadow: 0 2px 4px rgba(0,0,0,0.1);"
                >
                  {dgettext("booking", "Meeting Cancelled")}
                </h1>
                <p class="text-lg mb-8" style="color: rgba(255,255,255,0.9);">
                  {dgettext("booking", "Your meeting has been successfully cancelled.")}
                </p>

                <div
                  class="mb-8 p-4 rounded-lg flex items-start gap-3"
                  style="background: rgba(16, 185, 129, 0.1); border: 1px solid rgba(16, 185, 129, 0.2);"
                >
                  <svg
                    class="w-5 h-5 shrink-0 mt-0.5"
                    style="color: #10b981;"
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
                  <div class="text-sm" style="color: rgba(255,255,255,0.85);">
                    <strong>{dgettext(
                      "booking",
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
                    {dgettext("booking", "Schedule a New Meeting")}
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
