defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.TranscriptTest do
  @moduledoc """
  `Navigators.Transcript`'s callbacks on the shipped facts: where a route
  lands, which moments the conversation shows, its list frame, and that an
  edit names an answered moment or changes nothing. Editing on a real page is
  held by the fixture journey (`talk_journey_test.exs`).
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Transcript
  alias TymeslotWeb.Themes.Shared.PathHandlers

  @journey %Journey{
    navigator: Transcript,
    outcomes: %{},
    moments: [
      %Moment{key: :hello, collects: [:meeting_type], component: nil, defaults: []},
      %Moment{key: :day, collects: [], component: nil, defaults: []},
      %Moment{key: :time, collects: [:slot], component: nil, defaults: []},
      %Moment{key: :you, collects: [:attendee], component: nil, defaults: []}
    ]
  }

  defp socket,
    do: %Socket{assigns: %{__changed__: %{}, journey: @journey, current_state: :hello}}

  defp meeting_type do
    %MeetingTypeSchema{
      id: 1,
      name: "Quick Chat",
      slug: "quick-chat",
      duration_minutes: 30,
      is_active: true,
      custom_fields: []
    }
  end

  # A visitor whose slug link resolved the meeting type, as `Mount` leaves it.
  defp chosen(changes \\ %{}) do
    Map.merge(
      %{
        meeting_types: [meeting_type()],
        meeting_type: meeting_type(),
        selected_duration: "quick-chat",
        selected_date: nil,
        selected_time: nil
      },
      changes
    )
  end

  defp visible(assigns),
    do: for({moment, state} <- Transcript.visible(@journey, assigns), do: {moment.key, state})

  # The live action the router gives `path`, which is what a redirect to it
  # mounts with.
  defp live_action(path) do
    %{phoenix_live_view: {_view, action, _opts, _live_session}} =
      Phoenix.Router.route_info(TymeslotWeb.Router, "GET", URI.parse(path).path, "localhost")

    action
  end

  describe "entry/3" do
    test "lands each route on the moment collecting what it presets" do
      assert Transcript.entry(@journey, :overview, %{}) == :hello
      assert Transcript.entry(@journey, :schedule, %{}) == :time
      assert Transcript.entry(@journey, :booking, %{}) == :you
      assert Transcript.entry(@journey, :confirmation, %{}) == :confirmation
    end
  end

  describe "entry points" do
    test "a slug link lands on the times, the meeting type answered and the day asked" do
      assert Transcript.entry(@journey, :schedule, chosen()) == :time
      assert visible(chosen()) == [hello: :done, day: :open, time: :current]
    end

    test "a slug link with a date lands on the times, the day chosen and the time still open" do
      assigns = chosen(%{selected_date: "2027-03-10", available_slots: ["9:00 AM", "9:30 AM"]})

      assert Transcript.entry(@journey, :schedule, assigns) == :time
      assert visible(assigns) == [hello: :done, day: :open, time: :current]
    end

    test "a /book link with a date and time lands on the details, the answers above it" do
      assigns =
        chosen(%{
          selected_date: "2027-03-10",
          selected_time: "9:00 AM",
          available_slots: ["9:00 AM", "9:30 AM"]
        })

      assert Transcript.entry(@journey, :booking, assigns) == :you
      assert visible(assigns) == [hello: :done, day: :open, time: :done, you: :current]
    end

    test "a locale switch comes back on the route the visit started on, and lands where it did" do
      for start <- [:overview, :schedule, :booking] do
        socket = %Socket{
          assigns:
            Map.merge(chosen(%{selected_date: "2027-03-12", selected_time: "9:00 AM"}), %{
              __changed__: %{},
              journey: @journey,
              live_action: start,
              username_context: "ada",
              duration: "quick-chat"
            })
        }

        path = PathHandlers.build_path_with_locale(socket, "de")

        # The choices ride along; the type in the query only on the overview,
        # whose path does not name it.
        carried = %{"locale" => "de", "date" => "2027-03-12", "time" => "9:00 AM"}

        expected =
          if start == :overview, do: Map.put(carried, "duration", "quick-chat"), else: carried

        assert URI.decode_query(URI.parse(path).query) == expected
        assert live_action(path) == start

        assert Transcript.entry(@journey, live_action(path), socket.assigns) ==
                 Transcript.entry(@journey, start, socket.assigns)
      end
    end
  end

  describe "visible/2" do
    test "before any choice shows only the opening question" do
      assert visible(%{}) == [hello: :current]
    end

    test "shows nothing while an outcome is current" do
      assert visible(chosen(%{current_state: :confirmation})) == []
      assert visible(chosen(%{current_state: :awaiting_payment})) == []
    end
  end

  describe "go_to/3" do
    test "changes nothing for a moment that is not answered yet" do
      assert Transcript.go_to(@journey, socket(), "hello") == {:noreply, socket()}
    end

    test "changes nothing for a step that names no moment reached" do
      assert Transcript.go_to(@journey, socket(), "you") == {:noreply, socket()}
      assert Transcript.go_to(@journey, socket(), "3") == {:noreply, socket()}
      assert Transcript.go_to(@journey, socket(), nil) == {:noreply, socket()}
    end
  end

  describe "frame/0" do
    test "is an ordered list that announces what is added to it politely" do
      assert {"ol", attrs} = Transcript.frame()
      assert attrs[:class] =~ "journey--transcript"
      assert attrs[:"aria-live"] == "polite"
      assert attrs[:"aria-relevant"] == "additions"
    end
  end
end
