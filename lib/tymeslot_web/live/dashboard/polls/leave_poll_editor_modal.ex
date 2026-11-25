defmodule TymeslotWeb.Dashboard.Polls.LeavePollEditorModal do
  @moduledoc """
  Asks before a link takes the host away from an open poll's editor
  (`PollEditor`) with changes not yet saved.

  Saving on the way out, as the translation editor does, is no answer here:
  a saved change can email everyone on the poll, so the host decides. The
  editor's `UnsavedChanges` hook holds the link meanwhile. Stay and Leave
  dispatch `close_leave_poll_editor_modal` and `leave_poll_editor` to the
  parent component (`@myself`), which owns the modal's state and lets the
  link go.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :open, :boolean, required: true
  attr :myself, :any, required: true

  @spec leave_poll_editor_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def leave_poll_editor_modal(assigns) do
    ~H"""
    <.confirm_modal
      :if={@open}
      id="leave-poll-editor-modal"
      show
      size={:small}
      title={dgettext("dashboard_polls", "Leave without saving?")}
      confirm_label={dgettext("dashboard_polls", "Leave without saving")}
      cancel_label={dgettext("dashboard_polls", "Keep editing")}
      cancel_id="leave-poll-editor-cancel"
      on_cancel={JS.push("close_leave_poll_editor_modal", target: @myself)}
      on_confirm={JS.push("leave_poll_editor", target: @myself)}
      data-testid="confirm-leave-poll-editor"
    >
      <p>
        {dgettext(
          "dashboard_polls",
          "Your changes to this poll are not saved yet. Leaving now discards them."
        )}
      </p>
    </.confirm_modal>
    """
  end
end
