defmodule TymeslotWeb.Components.BackgroundMotionToggle do
  @moduledoc """
  Pause/play control for a theme's background video.

  WCAG 2.2 SC 2.2.2 (Pause, Stop, Hide, Level A) requires a mechanism to stop
  any motion that starts automatically, runs for more than five seconds, and is
  presented alongside other content. The booking-page backgrounds are looping
  autoplay videos behind the booking form, so they need one. The themes already
  honour `prefers-reduced-motion`, but that is an operating-system setting
  rather than a mechanism on the page, and it does not help a visitor who wants
  the rest of the page's motion left alone.

  Render this only where a video background is actually present: a control that
  pauses nothing is worse than no control. The behaviour lives entirely in the
  `BackgroundMotionToggle` JavaScript hook, which also hides the button when the
  video is dropped for another reason (reduced motion, a slow connection, a
  decode error).

  Shared by the booking themes and the auth pages, which is why it sits here
  rather than under `Themes.Shared` and why its strings live in the `common`
  gettext domain. The two contexts style `.background-motion-toggle` from their
  own token systems: `assets/css/scheduling/shared/background-motion.css` for the
  self-contained themes, `assets/css/components/background-motion.css` for
  everything served from `app.css`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  @doc """
  Renders the background-motion pause/play button.

  The accessible name is swapped by the hook to match the current state, so both
  labels are handed to the client as data attributes: the server cannot know
  which state a returning visitor stored.
  """
  @spec background_motion_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def background_motion_toggle(assigns) do
    ~H"""
    <button
      id="background-motion-toggle"
      type="button"
      class="background-motion-toggle"
      data-state="playing"
      data-label-pause={dgettext("common", "Pause background video")}
      data-label-play={dgettext("common", "Play background video")}
      aria-label={dgettext("common", "Pause background video")}
      title={dgettext("common", "Pause background video")}
      phx-hook="BackgroundMotionToggle"
    >
      <%!-- Both icons ship; theme CSS shows the one matching data-state, so the
           swap costs no round trip and survives a LiveView patch. --%>
      <.icon
        name="hero-pause-solid"
        class="background-motion-toggle__icon background-motion-toggle__icon--pause"
      />
      <.icon
        name="hero-play-solid"
        class="background-motion-toggle__icon background-motion-toggle__icon--play"
      />
    </button>
    """
  end
end
