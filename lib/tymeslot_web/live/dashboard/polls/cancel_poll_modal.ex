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
    <.confirm_modal
      :if={@open && @poll}
      id="cancel-poll-modal"
      show
      title={dgettext("dashboard_common", "Cancel this poll?")}
      confirm_label={dgettext("dashboard_common", "Cancel poll")}
      cancel_label={dgettext("dashboard_common", "Keep poll")}
      on_cancel={JS.push("close_cancel_poll_modal", target: @myself)}
      on_confirm={JS.push("cancel_poll", target: @myself)}
      data-testid="confirm-cancel-poll"
    >
      <p>
        {dgettext(
          "dashboard_common",
          "“%{title}” will stop accepting responses and everyone holding the voting link will see it as cancelled. This cannot be undone.",
          title: @poll.title
        )}
      </p>

      <:extra :if={@participant_count > 0}>
        <.info_box variant={:warning}>
          {dngettext(
            "dashboard_common",
            "%{count} guest has already voted. Their responses will be discarded.",
            "%{count} guests have already voted. Their responses will be discarded.",
            @participant_count
          )}
        </.info_box>
      </:extra>
    </.confirm_modal>
    """
  end
end
