defmodule TymeslotWeb.Themes.Shared.Components.PreviewNotice do
  @moduledoc """
  Tells a visitor that the booking page they are on is in owner-preview mode.

  Rendered by both theme wrappers (`Quill.Scheduling.Wrapper`,
  `Rhythm.Scheduling.Wrapper`) so it appears on every step of the booking
  flow, in embedded and standalone rendering alike, whenever
  `socket.assigns[:owner_preview]` is true.

  ## Why this exists

  An owner-preview token lets the page's own organiser test the booking flow
  without persisting a meeting, sending an email, or creating a calendar
  event (`booking_submission_handler_component.ex`'s `DemoOrchestrator`
  branch). The token verifies only against the page owner, not the browsing
  session, so anyone holding a copied preview URL gets the same simulated
  booking for the token's lifetime. Nothing distinguished that experience
  from a real one before this notice existed: a visitor who followed a
  leaked link saw an ordinary confirmation screen and believed they had
  booked. This banner is the disclosure half of that gap; the other half is
  making the preview link harder to copy in the first place
  (`embed_preview.js`'s Link style).

  Neutral class names here, visual treatment in each theme's own CSS module
  (`preview-notice.css`), following the same split as `ApprovalNotice`:
  the themes are self-contained and share no tokens.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  attr :owner_preview, :boolean, default: false

  @doc "Renders nothing unless `owner_preview` is true."
  @spec banner(map()) :: Phoenix.LiveView.Rendered.t()
  def banner(assigns) do
    ~H"""
    <div :if={@owner_preview} class="preview-notice" data-testid="preview-notice">
      <.icon name="hero-eye" class="preview-notice-icon" />
      <span class="preview-notice-text">
        {dgettext(
          "booking",
          "Preview mode: bookings made here are simulated. Nothing is saved or sent."
        )}
      </span>
    </div>
    """
  end
end
