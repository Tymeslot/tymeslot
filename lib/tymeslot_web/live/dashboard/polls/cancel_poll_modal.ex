defmodule TymeslotWeb.Dashboard.Polls.CancelPollModal do
  @moduledoc """
  Confirmation modal for cancelling an open poll.

  Stateless function component rendered by `PollsComponent`. Cancelling a poll
  is irreversible (`Polls.cancel_poll/2` only accepts open polls and nothing
  reopens one) and it closes the public voting page on every guest who already
  holds the link, so the destructive action is never one click away.

  The Keep/Cancel actions dispatch `close_cancel_poll_modal` and
  `cancel_poll` back to the parent component (`@myself`), which owns the
  modal's open/closed state and performs the cancellation.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :open, :boolean, required: true
  attr :poll, :map, default: nil
  attr :participant_count, :integer, default: 0
  attr :myself, :any, required: true

  @spec cancel_poll_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def cancel_poll_modal(assigns) do
    ~H"""
    <.modal
      :if={@open && @poll}
      id="cancel-poll-modal"
      show={true}
      on_cancel={JS.push("close_cancel_poll_modal", target: @myself)}
      size={:medium}
    >
      <:header>
        <span class="text-token-xl font-black tracking-tight">
          {dgettext("dashboard_common", "Cancel this poll?")}
        </span>
      </:header>

      <div class="space-y-4">
        <p class="text-tymeslot-700">
          {dgettext(
            "dashboard_common",
            "“%{title}” will stop accepting responses and everyone holding the voting link will see it as cancelled. This cannot be undone.",
            title: @poll.title
          )}
        </p>

        <.info_box :if={@participant_count > 0} variant={:warning}>
          {dngettext(
            "dashboard_common",
            "%{count} guest has already voted. Their responses will be discarded.",
            "%{count} guests have already voted. Their responses will be discarded.",
            @participant_count
          )}
        </.info_box>
      </div>

      <:footer>
        <div class="flex justify-end gap-3">
          <.action_button
            variant={:secondary}
            phx-click="close_cancel_poll_modal"
            phx-target={@myself}
          >
            {dgettext("dashboard_common", "Keep poll")}
          </.action_button>
          <.action_button variant={:danger} phx-click="cancel_poll" phx-target={@myself}>
            {dgettext("dashboard_common", "Cancel poll")}
          </.action_button>
        </div>
      </:footer>
    </.modal>
    """
  end
end
