defmodule TymeslotWeb.Themes.Shared.Blocks.SummaryBar do
  @moduledoc """
  What the visitor has chosen so far, for a journey that keeps its moments on
  one page (`Navigators.Continuous`): the meeting type and its length, then
  the day and time once both are chosen. Each item links to the moment that
  collected it (`#<moment>-step`, the id `SchedulingPage` gives the moment
  and its root element carries; the moment found through the journey,
  `Progress.moment_for/2`), so a visitor far down the page jumps back to
  change it. A plain link: it needs no round trip and reads as navigation.
  Nothing renders before a meeting type is chosen.

  A `nav` landmark labelled "Meeting Details", its items an ordered list.
  Classes: `summary-bar`, `__items`, `__item`, `__link`, `__value`,
  `__label`. `scheduling/shared/blocks/summary-bar.css` keeps it at the top
  of its scroll container as the page scrolls, on tokens only.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Utils.DateTimeUtils
  alias TymeslotWeb.Themes.Shared.BookingText
  alias TymeslotWeb.Themes.Shared.Journey.Progress
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :journey, :any, required: true, doc: "the page's `%Journey{}`"
  attr :meeting_type, :any, default: nil
  attr :selected_date, :string, default: nil
  attr :selected_time, :string, default: nil
  attr :user_timezone, :string, required: true

  @spec summary_bar(map()) :: Phoenix.LiveView.Rendered.t()
  def summary_bar(assigns) do
    assigns =
      assign(assigns,
        type_href: href(assigns.journey, :meeting_type),
        slot_href: href(assigns.journey, :slot),
        slot_label:
          slot_label(assigns.selected_date, assigns.selected_time, assigns.user_timezone)
      )

    ~H"""
    <nav
      :if={@meeting_type}
      class="summary-bar"
      data-testid="summary-bar"
      aria-label={dgettext("booking", "Meeting Details")}
    >
      <ol class="summary-bar__items">
        <li class="summary-bar__item">
          <a class="summary-bar__link" href={@type_href} data-testid="summary-bar-meeting-type">
            <span class="summary-bar__value">{@meeting_type.name}</span>
            <span class="summary-bar__label">
              {BookingText.duration_label(%{meeting_type: @meeting_type})}
            </span>
          </a>
        </li>
        <li :if={@slot_label} class="summary-bar__item">
          <a class="summary-bar__link" href={@slot_href} data-testid="summary-bar-slot">
            <span class="summary-bar__value">{@slot_label}</span>
          </a>
        </li>
      </ol>
    </nav>
    """
  end

  defp href(journey, fact) do
    case Progress.moment_for(journey, fact) do
      nil -> nil
      key -> "##{key}-step"
    end
  end

  # The day and time in the visitor's zone, as a list row writes a meeting;
  # the booking step's long form when the pair does not make a time there.
  defp slot_label(date, time, timezone) when is_binary(date) and is_binary(time) do
    with {:ok, day} <- Date.from_iso8601(date),
         {:ok, clock} <- DateTimeUtils.parse_time_string(time),
         {:ok, at} <- DateTime.new(day, clock, timezone) do
      LocalizationHelpers.format_meeting_datetime_compact(at, timezone)
    else
      _no_single_time -> LocalizationHelpers.format_booking_datetime(date, time, timezone)
    end
  end

  defp slot_label(_date, _time, _timezone), do: nil
end
