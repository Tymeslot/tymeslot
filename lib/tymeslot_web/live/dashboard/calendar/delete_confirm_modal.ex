defmodule TymeslotWeb.Dashboard.Calendar.DeleteConfirmModal do
  @moduledoc """
  Asks before a delete that tells someone: the calendar copy of a booking,
  whose meeting the delete cancels and whose guest is told, or an event the
  organiser invited guests to, who can be sent a cancellation or left out
  of it. Sends `calendar:confirm_delete` with `notify` `"true"` or
  `"false"`; Cancel, Escape and a click outside send `calendar:cancel_delete`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents.Modal

  attr :prompt, :map,
    required: true,
    doc: "`%{title: title, notice: :booking | {:attendees, count}}`"

  attr :target, :any, required: true

  @spec delete_confirm_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_confirm_modal(assigns) do
    ~H"""
    <Modal.confirm_modal
      id="calendar-delete-confirm"
      show
      size={:small}
      icon="hero-trash"
      title={dgettext("dashboard_calendar", "Delete “%{title}”?", title: @prompt.title)}
      on_cancel={JS.push("calendar:cancel_delete", target: @target)}
    >
      <p>{explanation(@prompt.notice)}</p>
      <:actions>
        <.action_button
          :if={match?({:attendees, _count}, @prompt.notice)}
          id="calendar-delete-quietly"
          variant={:secondary}
          phx-click="calendar:confirm_delete"
          phx-value-notify="false"
          phx-target={@target}
        >
          {dgettext("dashboard_calendar", "Delete without telling them")}
        </.action_button>
        <.action_button
          id="calendar-delete-notify"
          variant={:danger}
          phx-click="calendar:confirm_delete"
          phx-value-notify="true"
          phx-target={@target}
        >
          {confirm_label(@prompt.notice)}
        </.action_button>
      </:actions>
    </Modal.confirm_modal>
    """
  end

  defp explanation(:booking),
    do:
      dgettext(
        "dashboard_calendar",
        "This is the calendar copy of a booking. Deleting it cancels the booking and tells the guest."
      )

  defp explanation({:attendees, count}),
    do:
      dngettext(
        "dashboard_calendar",
        "It has %{count} guest. Do you want to send them a cancellation?",
        "It has %{count} guests. Do you want to send them a cancellation?",
        count
      )

  defp confirm_label(:booking),
    do: dgettext("dashboard_calendar", "Delete and cancel the booking")

  defp confirm_label({:attendees, _count}),
    do: dgettext("dashboard_calendar", "Delete and tell guests")
end
