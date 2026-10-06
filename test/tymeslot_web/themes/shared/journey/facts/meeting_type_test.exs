defmodule TymeslotWeb.Themes.Shared.Journey.Facts.MeetingTypeTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.Journey.Facts.MeetingType

  @intro %{name: "Intro call", slug: "intro-call", duration_minutes: 30}
  @quick %{name: "Quick chat", slug: "quick-chat", duration_minutes: 15}

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  test "is the meeting type, needed by every booking and needing nothing before it" do
    assert MeetingType.key() == :meeting_type
    assert MeetingType.requires(%{}) == []
    assert MeetingType.required?(%{})
    assert MeetingType.events() == [:select_duration]
  end

  describe "select_duration" do
    test "chooses the duration the booker picked" do
      assert {:noreply, socket} = MeetingType.handle(socket(%{}), :select_duration, "intro-call")

      assert socket.assigns.selected_duration == "intro-call"
      assert socket.assigns.duration == "intro-call"
    end

    test "keeps a pinned reschedule's type whatever the payload names" do
      socket = socket(%{meeting_type_pinned: true, selected_duration: "intro-call"})

      assert {:noreply, socket} = MeetingType.handle(socket, :select_duration, "quick-chat")
      assert socket.assigns.selected_duration == "intro-call"
    end
  end

  describe "known?/1 and continue/1" do
    test "a duration among the organiser's types is known and lets the booker on" do
      socket = socket(%{meeting_types: [@intro, @quick], selected_duration: "quick-chat"})

      assert MeetingType.known?(socket.assigns)
      assert MeetingType.continue(socket) == {:done, socket}
    end

    test "no choice yet is not known, and says why the booker cannot go on" do
      socket = socket(%{meeting_types: [@intro]})

      refute MeetingType.known?(socket.assigns)
      assert MeetingType.continue(socket) == {:error, :duration_required}
    end

    test "a duration the organiser does not offer is refused" do
      socket = socket(%{meeting_types: [@intro], selected_duration: "two-hours"})

      assert MeetingType.continue(socket) == {:error, :duration_invalid}
    end

    test "a private type reached by its own link counts though the public list lacks it" do
      socket =
        socket(%{meeting_types: [@intro], meeting_type: @quick, selected_duration: "quick-chat"})

      assert MeetingType.continue(socket) == {:done, socket}
    end

    test "a resolved meeting type is known on its own" do
      assert MeetingType.known?(%{meeting_type: @intro})
    end
  end

  test "back returns to it only for a booker who came through the overview" do
    assert MeetingType.revisitable?(%{entered_via_overview: true})
    refute MeetingType.revisitable?(%{entered_via_overview: false})
    refute MeetingType.revisitable?(%{})
  end

  describe "default/2" do
    test "takes the first and the shortest type" do
      assert MeetingType.default_strategies() == [:first, :shortest]
    end

    test ":first chooses the organiser's first type" do
      socket = MeetingType.default(socket(%{meeting_types: [@intro, @quick]}), :first)

      assert socket.assigns.selected_duration == "intro-call"
    end

    test ":shortest chooses the shortest type" do
      socket = MeetingType.default(socket(%{meeting_types: [@intro, @quick]}), :shortest)

      assert socket.assigns.selected_duration == "quick-chat"
    end

    test "leaves a known choice and an empty list alone" do
      known = socket(%{meeting_types: [@intro, @quick], selected_duration: "quick-chat"})
      empty = socket(%{meeting_types: []})

      assert MeetingType.default(known, :first) == known
      assert MeetingType.default(empty, :first) == empty
    end
  end
end
