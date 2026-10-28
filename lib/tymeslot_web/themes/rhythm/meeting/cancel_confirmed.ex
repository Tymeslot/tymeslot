defmodule TymeslotWeb.Themes.Rhythm.Meeting.CancelConfirmed do
  @moduledoc """
  Rhythm theme cancel confirmed component with modern sliding style.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Rhythm.Scheduling.Wrapper

  attr :theme_tokens, :any, required: true
  attr :locale, :string, required: true
  attr :language_dropdown_open, :boolean, required: true

  @doc """
  Renders the cancel confirmed page in Rhythm theme style.
  """
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Wrapper.rhythm_wrapper
      theme_tokens={@theme_tokens}
      locale={@locale}
      language_dropdown_open={@language_dropdown_open}
      show_language_switcher={true}
    >
      <div class="scheduling-box booker-card">
        <div class="slide-container">
          <div class="slide active">
            <div class="slide-content confirmation-slide">
              <div class="confirmation-container">
                <div class="confirmation-header-section">
                  <div class="success-badge">
                    <div class="success-badge-inner">
                      <.icon name="hero-check" class="success-icon stroke-3" />
                    </div>
                  </div>

                  <h1 class="confirmation-headline">
                    {dgettext("booking_manage", "Meeting Cancelled")}
                  </h1>

                  <p class="confirmation-message">
                    {dgettext("booking_manage", "Your meeting has been successfully cancelled.")}
                  </p>
                </div>

                <div class="meeting-ticket">
                  <div class="ticket-body">
                    <div class="email-confirmation">
                      <.icon name="hero-envelope" class="email-icon" />
                      <span>
                        <strong>{dgettext(
                          "booking_manage",
                          "Cancellation emails have been sent to all participants."
                        )}</strong>
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
                    {dgettext("booking_manage", "Schedule a New Meeting")}
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
