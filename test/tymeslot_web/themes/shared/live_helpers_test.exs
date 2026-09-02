defmodule TymeslotWeb.Themes.Shared.LiveHelpersTest do
  @moduledoc """
  Coverage for the seat-token handling in `handle_param_updates/2`.

  The token rides in the picker URL as `reschedule_seat_token`. If the seat it
  names dies mid-session (given up, reassigned), the next `handle_params` must
  actually drop it from the socket, not just recompute `is_rescheduling` while
  leaving the stale token assign in place for the submit path to keep reading.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Meetings.ParticipantQueries
  alias TymeslotWeb.Themes.Shared.LiveHelpers

  defp socket_with(assigns) do
    %Phoenix.LiveView.Socket{assigns: Map.merge(%{__changed__: %{}}, assigns)}
  end

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 4)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_ref: meeting_type,
        attendee_name: nil,
        attendee_email: nil
      )

    participant =
      insert(:participant, meeting: meeting, name: "Mover", email: "mover@example.com")

    %{participant: participant}
  end

  describe "maybe_subscribe_to_group_seats/1" do
    alias Tymeslot.MeetingTypes.MeetingTypeSchema

    defp connected_socket_with(assigns) do
      %Phoenix.LiveView.Socket{
        transport_pid: self(),
        assigns: Map.merge(%{__changed__: %{}}, assigns)
      }
    end

    defp group_type(id), do: %MeetingTypeSchema{id: id, max_participants: 4}

    test "returning to a type visited earlier does not subscribe a second time" do
      type_a = group_type(1)
      type_b = group_type(2)

      # Visit A, then B, then back to A — each call carries forward the
      # assigns (including the subscribed-ids set) the previous one left.
      socket_a = connected_socket_with(%{meeting_type: type_a})
      socket = LiveHelpers.maybe_subscribe_to_group_seats(socket_a)

      socket_b = connected_socket_with(Map.put(socket.assigns, :meeting_type, type_b))
      socket = LiveHelpers.maybe_subscribe_to_group_seats(socket_b)

      socket_a_again = connected_socket_with(Map.put(socket.assigns, :meeting_type, type_a))
      socket = LiveHelpers.maybe_subscribe_to_group_seats(socket_a_again)

      Phoenix.PubSub.broadcast(Tymeslot.PubSub, "group_seats:1", {:seat_update, 1})

      # A double subscription to the same topic would deliver the broadcast
      # twice; exactly one copy in the mailbox proves the second visit to
      # type A was a no-op.
      assert_receive {:seat_update, 1}
      refute_receive {:seat_update, 1}, 50

      assert socket.assigns.group_seats_subscribed_ids == MapSet.new([1, 2])
    end
  end

  describe "handle_param_updates/2" do
    test "keeps a still-live seat token assigned and rescheduling on", %{
      participant: participant
    } do
      socket = socket_with(%{})
      params = %{"reschedule_seat_token" => participant.management_token}

      updated = LiveHelpers.handle_param_updates(socket, params)

      assert updated.assigns.reschedule_seat_token == participant.management_token
      assert updated.assigns.is_rescheduling
    end

    test "drops a token that died mid-session, even though the assign still carries it", %{
      participant: participant
    } do
      {:ok, _cancelled} = ParticipantQueries.cancel(participant)

      # The assign carries the (now spent) token forward from before it died,
      # exactly as it would mid-session: the URL still names it because
      # nothing has cleared it yet.
      socket =
        socket_with(%{
          reschedule_seat_token: participant.management_token,
          is_rescheduling: true
        })

      params = %{"reschedule_seat_token" => participant.management_token}

      updated = LiveHelpers.handle_param_updates(socket, params)

      assert updated.assigns.reschedule_seat_token == nil
      refute updated.assigns.is_rescheduling
    end
  end
end
