defmodule TymeslotWeb.Dashboard.Polls.DeletePollModal do
  @moduledoc """
  Confirmation modal for deleting a poll that is over, confirmed or
  cancelled, to tidy the list (`Polls.delete_poll/2`).

  Stateless function component rendered by `PollsComponent`, which owns the
  modal's open/closed state and handles `close_delete_poll_modal` and
  `delete_poll`. Deleting cannot be undone, so it is never one click away.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :open, :boolean, required: true
  attr :poll, :map, default: nil
  attr :myself, :any, required: true

  @spec delete_poll_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_poll_modal(assigns) do
    ~H"""
    <.confirm_modal
      :if={@open && @poll}
      id="delete-poll-modal"
      show
      title={dgettext("dashboard_polls", "Delete this poll")}
      confirm_label={dgettext("dashboard_polls", "Delete poll")}
      cancel_label={dgettext("dashboard_polls", "Keep poll")}
      on_cancel={JS.push("close_delete_poll_modal", target: @myself)}
      on_confirm={JS.push("delete_poll", target: @myself)}
      data-testid="confirm-delete-poll"
    >
      <p>
        {dgettext(
          "dashboard_polls",
          "“%{title}” will be removed with its times and everyone's responses. This cannot be undone.",
          title: @poll.title
        )}
      </p>
      <p :if={@poll.status == :confirmed} class="mt-2">
        {dgettext("dashboard_polls", "The meeting it scheduled stays in your calendar.")}
      </p>
    </.confirm_modal>
    """
  end
end
