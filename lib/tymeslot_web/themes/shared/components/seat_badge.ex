defmodule TymeslotWeb.Themes.Shared.Components.SeatBadge do
  @moduledoc """
  Shared seats-left badge for group-booking time slots.

  Renders nothing for solo meeting types (`seats_left` is nil), so solo slot
  buttons keep their existing markup untouched. The traffic-light class
  (`seat-green`/`seat-amber`/`seat-red`) comes from
  `Tymeslot.Meetings.Seats.seat_level/2`. The markup is theme-agnostic and
  ships no styling of its own — each theme styles the `seat-badge`/`seat-*`
  classes in its own time-slots.css, following the `guest-*` convention.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Seats

  attr :seats_left, :integer, default: nil
  attr :capacity, :integer, default: nil

  @spec seat_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def seat_badge(%{seats_left: nil} = assigns) do
    ~H""
  end

  def seat_badge(assigns) do
    assigns = assign(assigns, :level, Seats.seat_level(assigns.seats_left, assigns.capacity))

    ~H"""
    <span class={["seat-badge", "seat-#{@level}"]} data-testid="seat-badge">
      {dngettext("booking", "%{count} seat left", "%{count} seats left", @seats_left,
        count: @seats_left
      )}
    </span>
    """
  end
end
