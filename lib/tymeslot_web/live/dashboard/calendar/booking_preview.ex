defmodule TymeslotWeb.Dashboard.Calendar.BookingPreview do
  @moduledoc """
  What a booking's preview offers: Accept and Decline on a request, and
  Reschedule and Cancel on a booking still ahead. Once the moment has passed a
  quiet line takes their place ("This meeting has ended", "This request
  expired without an answer"). A meeting under way offers none of those: it
  can no longer be cancelled or rescheduled, and its time row already says
  "Happening now".

  A booking whose event the host moved in their own calendar also offers
  "Move booking to …" (`BookingMove`), whatever its state, as the Meetings
  page's card does: a secondary action under the notice that says the event
  moved, offered only when `Tymeslot.Meetings.calendar_move_offers/1` made an
  offer for it.

  The server checks again on every action (`BookingActions`), so a preview
  left open past the moment cannot act on it.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.MeetingState

  @type state :: nil | :answer | :manage | {:note, String.t()}

  @doc "What the preview of `event` offers at `now`; nil for anything but a booking."
  @spec state(map(), DateTime.t()) :: state()
  def state(%{kind: :booking, expired: true}, _now), do: expired_note()

  # `expired` is decided when the window loads; a request left on screen past
  # its start or its approval deadline can no longer be answered either.
  def state(%{kind: :booking, request: true, start_at: %DateTime{} = start_at} = event, now) do
    if DateTime.compare(start_at, now) != :gt or
         MeetingState.approval_deadline_passed?(event, now),
       do: expired_note(),
       else: :answer
  end

  def state(
        %{kind: :booking, start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at},
        now
      ) do
    cond do
      DateTime.compare(end_at, now) != :gt ->
        {:note, dgettext("dashboard_calendar_booking", "This meeting has ended")}

      DateTime.compare(start_at, now) != :gt ->
        nil

      true ->
        :manage
    end
  end

  def state(_event, _now), do: nil

  attr :preview, :map, required: true

  attr :answering, :any,
    default: MapSet.new(),
    doc: "the ids of the meetings whose answer is in flight"

  attr :moving, :any, default: MapSet.new(), doc: "the ids of the bookings being moved"

  attr :target, :any, required: true

  @spec booking_actions(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_actions(assigns) do
    ~H"""
    <div
      :if={@preview.move_to}
      id="calendar-preview-moved"
      class="mt-4 border-t border-tymeslot-100 pt-3"
    >
      <p class="flex items-start gap-2 text-token-sm text-amber-800">
        <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 h-4 w-4 shrink-0" />
        {dgettext(
          "dashboard_bookings",
          "This meeting's event was rescheduled in your external calendar."
        )}
      </p>
      <div class="mt-2 flex justify-end">
        <.loading_button
          id="calendar-preview-move"
          variant={:secondary}
          size={:sm}
          icon="hero-calendar-days"
          class="whitespace-normal text-left"
          loading={MapSet.member?(@moving, @preview.meeting_id)}
          loading_text={dgettext("dashboard_calendar_booking", "Moving…")}
          phx-click="booking:move"
          phx-value-id={@preview.meeting_id}
          phx-target={@target}
        >
          {dgettext("dashboard_bookings", "Move booking to %{time}", time: @preview.move_to)}
        </.loading_button>
      </div>
    </div>
    <p
      :if={match?({:note, _text}, @preview.booking)}
      id="calendar-preview-note"
      class="mt-4 border-t border-tymeslot-100 pt-3 text-token-sm text-tymeslot-500"
    >
      {note(@preview.booking)}
    </p>
    <div
      :if={@preview.booking == :answer}
      class="mt-4 flex flex-wrap justify-end gap-2 border-t border-tymeslot-100 pt-3"
    >
      <.action_button
        id="calendar-preview-decline"
        variant={:secondary}
        size={:sm}
        icon="hero-x-mark"
        disabled={MapSet.member?(@answering, @preview.meeting_id)}
        phx-click="booking:decline"
        phx-value-id={@preview.meeting_id}
        phx-target={@target}
      >
        {dgettext("dashboard_calendar_booking", "Decline")}
      </.action_button>
      <.loading_button
        id="calendar-preview-accept"
        size={:sm}
        icon="hero-check"
        loading={MapSet.member?(@answering, @preview.meeting_id)}
        loading_text={dgettext("dashboard_calendar_booking", "Accepting…")}
        phx-click="booking:accept"
        phx-value-id={@preview.meeting_id}
        phx-target={@target}
      >
        {dgettext("dashboard_calendar_booking", "Accept")}
      </.loading_button>
    </div>
    <div
      :if={@preview.booking == :manage}
      class="mt-4 flex flex-wrap justify-end gap-2 border-t border-tymeslot-100 pt-3"
    >
      <.action_button
        id="calendar-preview-reschedule"
        variant={:secondary}
        size={:sm}
        icon="hero-arrows-right-left"
        phx-click="booking:reschedule"
        phx-value-id={@preview.meeting_id}
        phx-target={@target}
      >
        {dgettext("dashboard_calendar_booking", "Reschedule")}
      </.action_button>
      <.action_button
        id="calendar-preview-cancel"
        variant={:danger_soft}
        size={:sm}
        icon="hero-x-circle"
        phx-click="booking:cancel"
        phx-value-id={@preview.meeting_id}
        phx-target={@target}
      >
        {dgettext("dashboard_calendar_booking", "Cancel booking")}
      </.action_button>
    </div>
    """
  end

  defp note({:note, text}), do: text

  defp expired_note,
    do: {:note, dgettext("dashboard_calendar_booking", "This request expired without an answer")}
end
