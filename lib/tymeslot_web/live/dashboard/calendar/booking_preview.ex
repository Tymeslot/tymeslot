defmodule TymeslotWeb.Dashboard.Calendar.BookingPreview do
  @moduledoc """
  What a booking's preview offers: Accept and Decline on a request, and
  Reschedule and Cancel on a booking still ahead. Once the moment has passed
  a quiet line takes their place ("This meeting has ended", "This request
  expired without an answer"). A meeting under way offers nothing: it can no
  longer be cancelled or moved, and its time row already says "Happening
  now".

  The server checks again on every action (`BookingActions`), so a preview
  left open past the moment cannot act on it.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  @type state :: nil | :answer | :manage | {:note, String.t()}

  @doc "What the preview of `event` offers at `now`; nil for anything but a booking."
  @spec state(map(), DateTime.t()) :: state()
  def state(%{kind: :booking, expired: true}, _now),
    do: {:note, dgettext("dashboard_calendar_booking", "This request expired without an answer")}

  def state(%{kind: :booking, request: true}, _now), do: :answer

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
  attr :answering, :any, default: nil, doc: "the meeting whose answer is in flight"
  attr :target, :any, required: true

  @spec booking_actions(map()) :: Phoenix.LiveView.Rendered.t()
  def booking_actions(assigns) do
    ~H"""
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
        disabled={@answering == @preview.meeting_id}
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
        loading={@answering == @preview.meeting_id}
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
end
