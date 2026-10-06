defmodule TymeslotWeb.Themes.Shared.Components.GroupSession do
  @moduledoc """
  Tells a booking visitor that a meeting type is a group session, and a
  group participant moving their spot which spot they are moving.

  Without these the booking page reads like a one-to-one meeting from the
  first card to the thank-you screen. Three pieces, one per place:

    * `hint/1`: beside a group type in the overview list, how many people
      the session takes.
    * `confirmation_line/1`: on the thank-you screen, that the booking is
      one of those spots. It names nobody else on the session.
    * `seat_move_notice/1`: on the date step of a seat move, the time the
      spot is moving from.

  Each renders nothing for a meeting type that is not a group type (or no
  time to move from), so one-to-one pages keep their markup untouched. The
  markup is theme-neutral, styled by each theme's own `group-session.css`,
  as `ApprovalNotice` is.

  Callers pass the meeting type itself; SaaS demo organisers supply meeting
  types as plain maps, so the limit is read with `Map.get/2`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  attr :meeting_type, :any, required: true
  attr :class, :string, default: nil

  @doc "The compact marker for a group type in the overview list."
  @spec hint(map()) :: Phoenix.LiveView.Rendered.t()
  def hint(assigns) do
    assigns = assign(assigns, :capacity, capacity(assigns.meeting_type))

    ~H"""
    <span :if={@capacity} class={["group-session-hint", @class]} data-testid="group-session-hint">
      <.icon name="hero-user-group-micro" class="group-session-hint-icon" />
      <span>
        {dngettext(
          "booking",
          "Group session · up to %{count} person",
          "Group session · up to %{count} people",
          @capacity,
          count: @capacity
        )}
      </span>
    </span>
    """
  end

  attr :meeting_type, :any, required: true
  attr :class, :string, default: nil

  @doc "The thank-you screen's line: the booking is one spot of the session."
  @spec confirmation_line(map()) :: Phoenix.LiveView.Rendered.t()
  def confirmation_line(assigns) do
    assigns = assign(assigns, :capacity, capacity(assigns.meeting_type))

    ~H"""
    <p
      :if={@capacity}
      class={["group-session-line", @class]}
      data-testid="group-session-line"
    >
      <.icon name="hero-user-group-mini" class="group-session-line-icon" />
      <span>
        {dngettext(
          "booking",
          "Group session: you have one of %{count} spot.",
          "Group session: you have one of %{count} spots.",
          @capacity,
          count: @capacity
        )}
      </span>
    </p>
    """
  end

  attr :from, :any, required: true, doc: "the start of the spot being moved, or nil"
  attr :timezone, :string, default: nil
  attr :class, :string, default: nil

  @doc "The date step's notice of the spot a seat move is moving."
  @spec seat_move_notice(map()) :: Phoenix.LiveView.Rendered.t()
  def seat_move_notice(assigns) do
    ~H"""
    <div
      :if={@from}
      class={["group-session-move", @class]}
      role="status"
      data-testid="seat-move-notice"
    >
      <.icon name="hero-arrows-right-left-mini" class="group-session-line-icon" />
      <span>
        {dgettext("booking", "Moving your spot on %{datetime}. Pick a new time below.",
          datetime: LocalizationHelpers.format_meeting_datetime(@from, @timezone)
        )}
      </span>
    </div>
    """
  end

  defp capacity(meeting_type) do
    case meeting_type && Map.get(meeting_type, :max_participants) do
      count when is_integer(count) and count > 1 -> count
      _not_a_group -> nil
    end
  end
end
