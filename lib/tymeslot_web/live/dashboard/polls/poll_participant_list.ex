defmodule TymeslotWeb.Dashboard.Polls.PollParticipantList do
  @moduledoc """
  LiveComponent for the participant list in the poll editor.

  Lists everyone counted on an open poll, with a way to send someone their
  link again (`Polls.resend_invitation/3`) or to take them off the poll after
  a confirmation (`Polls.remove_participant/3`, see `RemoveParticipantModal`).
  Resending is greyed out once voting has closed, with the reason in its
  tooltip; the domain refuses it either way.

  The editor passes the poll it shows, so a vote arriving while the host edits
  refreshes the list, and whether it takes votes, as `PollsComponent` judged
  it, so the resend actions close with voting at the deadline. Answers reach the host as flashes through
  `TymeslotWeb.Live.Shared.Flash`, and a removal tells the owning
  `PollsComponent` to reload the poll.
  """
  use TymeslotWeb, :live_component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollParticipantSchema
  alias TymeslotWeb.Dashboard.Polls.{PollInvite, PollsComponent, RemoveParticipantModal}
  alias TymeslotWeb.Live.Shared.Flash

  @impl Phoenix.LiveComponent
  def mount(socket), do: {:ok, assign(socket, removing: nil, expanded?: false)}

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <div data-testid="poll-participant-list">
      <%!-- A disclosure held in assigns rather than a native <details>: the
            re-render after a resend or a live vote would otherwise close a
            list the host has open. --%>
      <div :if={@poll.participants != []} class="text-token-sm" data-testid="poll-participants">
        <button
          type="button"
          phx-click="toggle_participants"
          phx-target={@myself}
          aria-expanded={to_string(@expanded?)}
          aria-controls={"poll-participants-#{@poll.id}"}
          class="flex items-center gap-1 font-medium text-tymeslot-700"
          data-testid="poll-participants-toggle"
        >
          <.icon
            name={if @expanded?, do: "hero-chevron-down-mini", else: "hero-chevron-right-mini"}
            class="w-4 h-4"
          />
          {dngettext(
            "dashboard_polls",
            "%{count} participant",
            "%{count} participants",
            length(@poll.participants)
          )}
        </button>
        <ul
          id={"poll-participants-#{@poll.id}"}
          hidden={!@expanded?}
          class="mt-2 divide-y divide-tymeslot-100"
        >
          <li
            :for={participant <- @poll.participants}
            class="flex items-center justify-between gap-3 py-2"
            data-testid="poll-participant"
          >
            <div class="min-w-0">
              <p class="truncate text-tymeslot-800">{name(participant)}</p>
              <p class="truncate text-token-xs text-tymeslot-500">
                {participant.email} · {status_label(participant)}
              </p>
            </div>
            <div class="flex shrink-0 items-center gap-1">
              <.icon_button
                icon="hero-paper-airplane"
                label={resend_label(participant)}
                tooltip={resend_tooltip(participant, @voting_open?)}
                aria-disabled={if @voting_open?, do: nil, else: "true"}
                phx-click="resend_invitation"
                phx-value-id={participant.id}
                phx-target={@myself}
                data-testid="poll-resend-invitation"
              />
              <.icon_button
                icon="hero-user-minus"
                label={
                  dgettext("dashboard_polls", "Remove %{name} from the poll", name: name(participant))
                }
                tooltip={dgettext("dashboard_polls", "Remove from the poll")}
                phx-click="request_remove_participant"
                phx-value-id={participant.id}
                phx-target={@myself}
                data-testid="poll-remove-participant"
              />
            </div>
          </li>
        </ul>
      </div>

      <RemoveParticipantModal.remove_participant_modal
        id={"remove-participant-modal-#{@poll.id}"}
        participant={@removing}
        myself={@myself}
      />
    </div>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_participants", _params, socket),
    do: {:noreply, update(socket, :expanded?, &(!&1))}

  # The modal names someone from the poll the editor shows. An id from the
  # client that is not among its participants opens nothing.
  def handle_event("request_remove_participant", %{"id" => participant_id}, socket) do
    removing = Enum.find(socket.assigns.poll.participants, &(&1.id == participant_id))
    {:noreply, assign(socket, :removing, removing)}
  end

  def handle_event("close_remove_participant_modal", _params, socket),
    do: {:noreply, assign(socket, :removing, nil)}

  def handle_event("remove_participant", _params, %{assigns: %{removing: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("remove_participant", _params, socket) do
    %{poll: poll, user_id: user_id, removing: participant} = socket.assigns

    case Polls.remove_participant(poll.id, user_id, participant.id) do
      :ok ->
        Flash.info(
          dgettext("dashboard_polls", "Removed %{name} from the poll.", name: name(participant))
        )

      {:error, reason} ->
        Flash.warning(removal_error(reason))
    end

    send_update(PollsComponent, id: socket.assigns.parent_id, poll_updated: poll.id)
    {:noreply, assign(socket, :removing, nil)}
  end

  # The domain decides whether anything goes out; the participant from the
  # editor's poll only names them in the answer. An id that is not among them
  # is answered without asking the domain.
  def handle_event("resend_invitation", %{"id" => participant_id}, socket) do
    %{poll: poll, user_id: user_id} = socket.assigns

    case Enum.find(poll.participants, &(&1.id == participant_id)) do
      nil ->
        Flash.warning(removal_error(:not_found))

      participant ->
        case Polls.resend_invitation(poll.id, user_id, participant.id) do
          :ok -> Flash.info(resend_message(:ok, participant))
          {:error, reason} -> Flash.warning(resend_message(reason, participant))
        end
    end

    {:noreply, socket}
  end

  defp removal_error(:not_found),
    do: dgettext("dashboard_polls", "They are no longer on this poll.")

  defp removal_error(:not_open), do: dgettext("dashboard_polls", "This poll is no longer open.")

  defp resend_label(participant) do
    if Polls.unanswered_invitee?(participant),
      do: dgettext("dashboard_polls", "Resend invitation to %{name}", name: name(participant)),
      else: dgettext("dashboard_polls", "Resend voting link to %{name}", name: name(participant))
  end

  defp resend_tooltip(_participant, false), do: resend_message(:voting_closed, nil)

  defp resend_tooltip(participant, true) do
    if Polls.unanswered_invitee?(participant),
      do: dgettext("dashboard_polls", "Resend invitation"),
      else: dgettext("dashboard_polls", "Resend voting link")
  end

  defp resend_message(:ok, participant),
    do: dgettext("dashboard_polls", "Sent %{name} their link again.", name: name(participant))

  defp resend_message(:sent_recently, participant),
    do:
      dgettext(
        "dashboard_polls",
        "%{name} was sent their link a few minutes ago. Please wait a little before sending it again.",
        name: name(participant)
      )

  defp resend_message(:recipient_rate_limited, participant),
    do:
      dgettext(
        "dashboard_polls",
        "%{name} has had too many emails recently. Please try again later.",
        name: name(participant)
      )

  defp resend_message(:host_rate_limited, _participant),
    do:
      dgettext(
        "dashboard_polls",
        "You have sent too many invitations recently. Please try again later."
      )

  defp resend_message(:voting_closed, _participant),
    do:
      dgettext(
        "dashboard_polls",
        "Voting on this poll has closed. Move the deadline to send links again."
      )

  defp resend_message(reason, _participant) when reason in [:no_username, :no_calendar],
    do: PollInvite.error_message(reason)

  defp resend_message(reason, _participant) when reason in [:not_found, :not_open],
    do: removal_error(reason)

  defp name(participant), do: PollParticipantSchema.display_name(participant)

  defp status_label(%{voted_at: %DateTime{}}), do: dgettext("dashboard_polls", "voted")
  defp status_label(%{invited_at: %DateTime{}}), do: dgettext("dashboard_polls", "invited")
  defp status_label(_participant), do: dgettext("dashboard_polls", "not voted yet")
end
