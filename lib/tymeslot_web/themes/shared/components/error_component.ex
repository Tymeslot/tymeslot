defmodule TymeslotWeb.Themes.Shared.Components.ErrorComponent do
  @moduledoc """
  Shared readiness notice, rendered by every theme in place of the booking flow
  when the organiser cannot take bookings yet.

  It faces the public, so it carries the explanation and nothing else: no reason
  code, no retry affordance, since nothing a booker can do changes the
  organiser's setup.

  Styled with its own `readiness-notice-*` classes from
  `assets/css/scheduling/shared/layout.css`, the way `AwaitingPayment` is. The
  theme bundles are compiled independently of `app.css`, so the core's
  dashboard components cannot be borrowed here: `glass_morphism_card` renders a
  `.glass-morphism-card` that only Quill defines, which left Rhythm showing bare
  text over its background video.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div class="readiness-notice-container" data-testid="readiness-notice">
      <div class="readiness-notice-card">
        <div class="readiness-notice-icon" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12 9v2m0 4h.01M4.93 4.93l14.14 14.14M12 2a10 10 0 100 20 10 10 0 000-20z"
            />
          </svg>
        </div>
        <h1 class="readiness-notice-heading">
          {dgettext("errors", "calendar_setup_required")}
        </h1>
        <p class="readiness-notice-message">{@message}</p>
        <p class="readiness-notice-hint">
          {dgettext("errors", "connect_calendar_first")}
        </p>
      </div>
    </div>
    """
  end
end
