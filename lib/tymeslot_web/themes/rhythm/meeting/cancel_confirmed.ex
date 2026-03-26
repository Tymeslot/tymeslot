defmodule TymeslotWeb.Themes.Rhythm.Meeting.CancelConfirmed do
  @moduledoc """
  Rhythm theme cancel confirmed component with modern sliding style.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  attr :theme_customization, :map, required: true
  attr :custom_css, :string, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true

  @doc """
  Renders the cancel confirmed page in Rhythm theme style.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.rhythm_wrapper
      theme_customization={@theme_customization}
      custom_css={@custom_css}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="scheduling-box">
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content confirmation-slide">
              <div class="confirmation-container">
                <div class="confirmation-header-section">
                  <div class="success-badge">
                    <div class="success-badge-inner">
                      <svg class="success-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="3"
                          d="M5 13l4 4L19 7"
                        />
                      </svg>
                    </div>
                  </div>

                  <h1 class="confirmation-headline">
                    {gettext("Meeting Cancelled")}
                  </h1>

                  <p class="confirmation-message">
                    {gettext("Your meeting has been successfully cancelled.")}
                  </p>
                </div>
                
                <div class="meeting-ticket">
                  <div class="ticket-body">
                    <div class="email-confirmation">
                      <svg class="email-icon" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M3 8l7.89 5.26a2 2 0 002.22 0L21 8M5 19h14a2 2 0 002-2V7a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
                        />
                      </svg>
                      <span>
                        <strong>{gettext("Cancellation emails have been sent to all participants.")}</strong>
                      </span>
                    </div>
                  </div>
                </div>
                
                <div class="confirmation-actions">
                  <button
                    phx-click={JS.navigate("/")}
                    class="action-button-primary action-button-full-width"
                    type="button"
                  >
                    {gettext("Schedule a New Meeting")}
                  </button>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Wrapper.rhythm_wrapper>
    """
  end
end
