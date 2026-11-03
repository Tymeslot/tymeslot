defmodule TymeslotWeb.Themes.Shared.Components.MeetingTypeDescription do
  @moduledoc """
  The chosen meeting type's description on a booking step after the
  meeting-type choice, so a booker who opened one of several similar types
  can still read which one they are booking.

  The description starts cut to a few lines, so a long one (an organiser may
  write up to 500 characters) cannot push the calendar off a small screen.
  The cut is visual only, so a screen reader reads the full text. A toggle
  shows the rest; the `ClampedText` hook (`assets/js/hooks/clamped_text.js`)
  offers it only when the text really runs past the cut, which depends on
  the card's width and the language. The toggle is a client-side
  `Phoenix.LiveView.JS` command, which survives the step's re-renders and
  needs no server round trip.

  The markup is theme-neutral, styled by the shared
  `assets/css/scheduling/shared/components/meeting-type-description.css`
  through each theme's tokens. Renders nothing for a type without a
  description (`BookingText.description/1`).
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Themes.Shared.BookingText

  attr :id, :string, required: true, doc: "unique on the page; the toggle targets it"
  attr :meeting_type, :map, default: nil
  attr :class, :any, default: nil

  @spec description(map()) :: Phoenix.LiveView.Rendered.t()
  def description(assigns) do
    assigns = assign(assigns, :text, BookingText.description(assigns.meeting_type))

    ~H"""
    <div
      :if={@text}
      id={@id}
      class={["meeting-type-description", @class]}
      phx-hook="ClampedText"
      data-testid="meeting-type-description"
    >
      <p id={"#{@id}-text"} class="meeting-type-description__text" data-clamped-text>{@text}</p>
      <button
        type="button"
        class="meeting-type-description__toggle"
        aria-expanded="false"
        aria-controls={"#{@id}-text"}
        phx-click={toggle(@id)}
      >
        <span class="meeting-type-description__more">{dgettext("booking", "Show more")}</span>
        <span class="meeting-type-description__less">{dgettext("booking", "Show less")}</span>
      </button>
    </div>
    """
  end

  defp toggle(id) do
    JS.toggle_attribute(
      JS.toggle_class("is-expanded", to: "##{id}"),
      {"aria-expanded", "true", "false"}
    )
  end
end
