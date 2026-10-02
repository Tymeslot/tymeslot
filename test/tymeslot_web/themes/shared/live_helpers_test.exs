defmodule TymeslotWeb.Themes.Shared.LiveHelpersTest do
  @moduledoc """
  Coverage for the seat-token handling in `handle_param_updates/2`, and for
  the booking entry with a meeting type that is not a stored one.

  The token rides in the picker URL as `reschedule_seat_token`. If the seat it
  names dies mid-session (given up, reassigned), the next `handle_params` must
  actually drop it from the socket, not just recompute `is_rescheduling` while
  leaving the stale token assign in place for the submit path to keep reading.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.Meetings.Guests
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
      # The time the spot is moving from, for the date step's notice.
      assert %DateTime{} = updated.assigns.reschedule_seat_from
      assert updated.redirected == nil
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
          flash: %{},
          username_context: "host",
          reschedule_seat_token: participant.management_token,
          is_rescheduling: true
        })

      params = %{
        "username" => "host",
        "slug" => "workshop",
        "timezone" => "UTC",
        "reschedule_seat_token" => participant.management_token
      }

      updated = LiveHelpers.handle_param_updates(socket, params)

      assert updated.assigns.reschedule_seat_token == nil
      assert updated.assigns.reschedule_seat_from == nil
      refute updated.assigns.is_rescheduling

      # Sent on to a fresh booking from the start, without the spent token
      # but with the rest of the page's query, and told why.
      assert {:live, :redirect, %{to: "/host?timezone=UTC"}} = updated.redirected
      assert updated.assigns.flash["info"] =~ "already been used"
    end
  end

  describe "handle_booking_entry/2 with a plain-map meeting type" do
    # A demo organiser's meeting types are synthesised as plain maps rather
    # than stored. The guest cap asked the struct-only group predicate about
    # one on every entry into the booking step, and the page crashed there.
    test "enters the booking step with the flat guest cap" do
      demo_type = %{
        id: 1,
        name: "Demo call",
        duration: "30min",
        allow_guests: true,
        max_participants: 3
      }

      socket =
        socket_with(%{
          meeting_type_pinned: true,
          meeting_type: demo_type,
          selected_date: Date.add(Date.utc_today(), 1),
          selected_time: "10:00",
          available_slots: [%{time: "10:00", seats_left: 1, capacity: 3}],
          guest_emails: [],
          organizer_user_id: nil
        })

      updated = LiveHelpers.handle_booking_entry(socket, %{})

      assert updated.assigns.max_guests == Guests.max_guests()
      assert %Phoenix.HTML.Form{} = updated.assigns.form
    end
  end
end
