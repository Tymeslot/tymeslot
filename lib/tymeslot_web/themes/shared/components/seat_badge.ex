defmodule TymeslotWeb.Themes.Shared.Components.SeatBadge do
  @moduledoc """
  Shared spots badge for group-booking time slots.

  What a slot says about its spots is the organiser's choice, decided by
  `Tymeslot.Meetings.Seats.display/3`: a traffic-light level, the exact
  count once the slot is down to its last few spots, both, or nothing.
  `display/2` resolves that for a slot; `seat_badge/1` renders the result.
  Solo slots and slots with nothing to show render nothing, so their
  buttons keep the single-line markup.

  The level is always named in words ("Filling up"), never by colour alone.
  The markup is theme-agnostic and ships no styling of its own: the
  `seat-badge`/`seat-*` classes are styled in the shared
  `assets/css/scheduling/shared/components/slot-list.css`, beside the slot
  button `SlotList` renders them in, and each theme sets the `--seat-*`
  colours in its own `variables.css`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Seats

  @doc """
  What `slot` shows under `meeting_type`'s display settings, or `nil`.

  SaaS demo organisers supply meeting types as plain maps, so a missing
  setting reads as its schema default.
  """
  @spec display(map(), map() | nil) :: Seats.display()
  def display(%{seats_left: seats_left, capacity: capacity}, meeting_type)
      when is_integer(seats_left) and seats_left > 0 and is_integer(capacity) do
    Seats.display(seats_left, capacity, meeting_type || %{})
  end

  def display(_slot, _meeting_type), do: nil

  attr :display, :map, default: nil

  @spec seat_badge(map()) :: Phoenix.LiveView.Rendered.t()
  def seat_badge(%{display: nil} = assigns) do
    ~H""
  end

  def seat_badge(assigns) do
    ~H"""
    <span
      class={["seat-badge", "seat-#{@display.level || :neutral}"]}
      data-testid="seat-badge"
    >
      {label(@display)}
    </span>
    """
  end

  defp label(%{spots_left: count}) when is_integer(count),
    do: dngettext("booking", "%{count} spot left", "%{count} spots left", count, count: count)

  defp label(%{level: :green}), do: dgettext("booking", "Plenty left")
  defp label(%{level: :amber}), do: dgettext("booking", "Filling up")
  defp label(%{level: :red}), do: dgettext("booking", "Almost full")
end
