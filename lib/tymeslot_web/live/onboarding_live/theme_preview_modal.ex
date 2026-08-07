defmodule TymeslotWeb.OnboardingLive.ThemePreviewModal do
  @moduledoc """
  Full-screen modal that previews the user's real booking page during
  onboarding.

  Hosts an iframe pointed at the user's own page in same-origin owner-preview
  mode (`?preview=true`, loaded standalone rather than embedded), so it renders
  the actual selected theme, colours and video background filling the frame —
  exactly as invitees see it — rather than a mock or a chrome-stripped card.
  The parent LiveView owns the `show`/`url` state and the `close_theme_preview`
  event.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [modal: 1]

  alias Phoenix.LiveView.JS

  @doc """
  Renders the booking-page preview modal.

  ## Attributes

  * `show` - Whether the modal is visible
  * `url` - The embed-preview URL to load in the iframe (nil hides the frame)
  """
  attr :show, :boolean, required: true
  attr :url, :string, default: nil

  @spec theme_preview_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_preview_modal(assigns) do
    ~H"""
    <.modal
      id="onboarding-theme-preview"
      show={@show}
      size={:full}
      on_cancel={JS.push("close_theme_preview")}
    >
      <:header>{dgettext("onboarding_wizard", "Your booking page")}</:header>
      <%!-- The standalone page fills the frame (100vh), so the iframe maxes out
           the modal body; the dark backdrop only shows briefly while it loads. --%>
      <iframe
        :if={@url}
        src={@url}
        title={dgettext("onboarding_wizard", "Booking page preview")}
        class="w-full h-full rounded-token-xl border border-tymeslot-100"
        style="background-color: #1a1f2e;"
      ></iframe>
    </.modal>
    """
  end
end
