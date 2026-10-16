defmodule TymeslotWeb.Themes.Shared.Journey.RuntimeMomentsTest do
  @moduledoc """
  What showing a moment does (`Runtime.open_moment/3`): a moment's
  `defaults:` fill a fact the visitor has not chosen, never one they have,
  and the moment is recorded as open. And `Runtime.settle/1` leaves a page
  whose navigator reveals nothing by itself (`Paged`) as it was.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :themes
  @moduletag :integration

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine, as: QEngine
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Facts.MeetingType
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @moment %Moment{
    key: :now,
    collects: [:meeting_type],
    component: nil,
    defaults: [meeting_type: :first]
  }

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "defaults-page", timezone: "Etc/UTC")
    first = insert(:meeting_type, user: user, name: "Quick Chat", sort_order: 0)

    second =
      insert(:meeting_type, user: user, name: "Long Talk", duration_minutes: 60, sort_order: 1)

    # The organiser's page before any choice; no calendar window yet, so
    # nothing is fetched.
    socket = %Socket{
      assigns: %{
        __changed__: %{},
        journey: %Journey{navigator: Paged, moments: [@moment], outcomes: %{}},
        current_state: :now,
        username_context: profile.username,
        organizer_user_id: user.id,
        organizer_profile: profile,
        meeting_types: [first, second],
        meeting_type: nil,
        meeting_type_pinned: false,
        selected_duration: nil,
        duration: nil,
        reschedule_meeting_uid: nil,
        engine: QEngine.init([])
      }
    }

    %{socket: socket, first: first, second: second}
  end

  describe "open_moment/3" do
    test "applies the moment's default to a fact nobody has chosen", %{
      socket: socket,
      first: first
    } do
      refute MeetingType.known?(socket.assigns)

      opened = Runtime.open_moment(socket, @moment, %{})

      assert MeetingType.known?(opened.assigns)
      assert opened.assigns.meeting_type.id == first.id
    end

    test "leaves a fact the visitor chose alone", %{socket: socket, second: second} do
      {:noreply, chosen} = MeetingType.handle(socket, :select_duration, "long-talk")

      opened = Runtime.open_moment(chosen, @moment, %{})

      assert opened.assigns.meeting_type.id == second.id
    end

    test "records the moment as open", %{socket: socket} do
      opened = Runtime.open_moment(socket, @moment, %{})

      assert MapSet.member?(opened.assigns.journey_opened, :now)
    end
  end

  describe "settle/1" do
    test "returns the socket unchanged for a navigator without settle/2", %{socket: socket} do
      assert Runtime.settle(socket) == socket
    end
  end
end
