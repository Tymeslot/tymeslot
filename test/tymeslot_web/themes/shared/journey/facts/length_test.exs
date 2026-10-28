defmodule TymeslotWeb.Themes.Shared.Journey.Facts.LengthTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Quill.Scheduling.Live, as: QuillLive
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Facts.{Length, Slot}
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

  @several %{duration_minutes: 30, extra_lengths_minutes: [60, 15]}
  @one %{duration_minutes: 30, extra_lengths_minutes: []}

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  defp asking(assigns), do: Map.merge(%{journey: QuillLive.__journey__()}, assigns)

  test "is the length, needed once the meeting type is known, from select_length" do
    assert Length.key() == :length
    assert Length.requires(%{}) == [:meeting_type]
    assert Length.events() == [:select_length]
    assert Journey.facts()[:length] == Length
  end

  describe "required?/1" do
    test "for a type offering several lengths, on a journey that asks it" do
      assert Length.required?(asking(%{meeting_type: @several}))
    end

    test "not for a type with one length" do
      refute Length.required?(asking(%{meeting_type: @one}))
    end

    test "not on a reschedule, which keeps the booked length" do
      refute Length.required?(asking(%{meeting_type: @several, reschedule_meeting_uid: "uid"}))
    end

    test "not on a journey without a moment asking it" do
      journey =
        Journey.new(
          navigator: Paged,
          moments: [{:overview, collects: [:meeting_type], component: nil}],
          outcomes: %{}
        )

      refute Length.required?(%{journey: journey, meeting_type: @several})
    end
  end

  describe "known?/1 and continue/1" do
    test "a length the type offers lets the booker on" do
      socket = socket(asking(%{meeting_type: @several, chosen_length_minutes: 60}))

      assert Length.known?(socket.assigns)
      assert Length.continue(socket) == {:done, socket}
    end

    test "no length, or one the type does not offer, says which" do
      none = socket(asking(%{meeting_type: @several, chosen_length_minutes: nil}))
      other = socket(asking(%{meeting_type: @several, chosen_length_minutes: 45}))

      assert Length.continue(none) == {:error, :duration_required}
      assert Length.continue(other) == {:error, :duration_invalid}
    end
  end

  test "a length the type does not offer is ignored" do
    socket = socket(asking(%{meeting_type: @several, chosen_length_minutes: 30}))

    assert {:noreply, ^socket} = Length.handle(socket, :select_length, "45")
    assert {:noreply, ^socket} = Length.handle(socket, :select_length, %{"bogus" => 1})
  end

  test "clearing forgets the chosen length" do
    socket = socket(asking(%{meeting_type: @several, chosen_length_minutes: 60}))

    assert Length.clear(socket).assigns.chosen_length_minutes == nil
  end

  describe "the slot" do
    test "needs the length when the booker picks one, so a new one forgets the time" do
      assert Slot.requires(asking(%{meeting_type: @several})) == [:meeting_type, :length]
      assert Slot.requires(asking(%{meeting_type: @one})) == [:meeting_type]
    end
  end

  describe "pending_moment/1" do
    test "names the moment asking the length while none is chosen" do
      assert Length.pending_moment(asking(%{meeting_type: @several})) == :length

      assert Length.pending_moment(asking(%{meeting_type: @several, chosen_length_minutes: 15})) ==
               nil

      assert Length.pending_moment(asking(%{meeting_type: @one})) == nil
    end
  end
end
