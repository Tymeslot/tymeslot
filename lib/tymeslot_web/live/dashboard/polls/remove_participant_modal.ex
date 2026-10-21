defmodule TymeslotWeb.Dashboard.Polls.RemoveParticipantModal do
  @moduledoc """
  Confirmation modal for taking someone off an open poll with their
  responses (`Polls.remove_participant/3`).

  Stateless function component rendered by `PollEditor`, which holds the
  participant being removed (or nil) and handles
  `close_remove_participant_modal` and `remove_participant`. The person is
  not told and their responses cannot be brought back, so the removal is
  never one click away.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView.JS
  alias Tymeslot.Polls.PollParticipantSchema

  attr :id, :string, required: true
  attr :participant, :map, default: nil
  attr :myself, :any, required: true

  @spec remove_participant_modal(map()) :: Phoenix.LiveView.Rendered.t()
  def remove_participant_modal(assigns) do
    ~H"""
    <.confirm_modal
      :if={@participant}
      id={@id}
      show
      title={dgettext("dashboard_polls", "Remove from the poll")}
      confirm_label={dgettext("dashboard_polls", "Remove")}
      cancel_label={dgettext("dashboard_polls", "Keep")}
      on_cancel={JS.push("close_remove_participant_modal", target: @myself)}
      on_confirm={JS.push("remove_participant", target: @myself)}
      data-testid="confirm-remove-participant"
    >
      <p>
        {dgettext(
          "dashboard_polls",
          "Remove %{name} and their responses from this poll? They are not told.",
          name: PollParticipantSchema.display_name(@participant)
        )}
      </p>
    </.confirm_modal>
    """
  end
end
