defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.ContinuousTest do
  @moduledoc """
  `Navigators.Continuous`'s callbacks on the shipped facts: where a route
  lands, which moments a booking shows, and its frame. Revealing moments on a
  real page is held by the fixture journey (`scroll_journey_test.exs`).
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Phoenix.LiveView.Socket
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Continuous
  alias TymeslotWeb.Themes.Shared.PathHandlers

  @journey %Journey{
    navigator: Continuous,
    outcomes: %{},
    moments: [
      %Moment{key: :intro, collects: [], component: nil, defaults: []},
      %Moment{key: :offer, collects: [:meeting_type], component: nil, defaults: []},
      %Moment{key: :ask, collects: [:answers], component: nil, defaults: []},
      %Moment{key: :when, collects: [:slot], component: nil, defaults: []},
      %Moment{key: :you, collects: [:attendee], component: nil, defaults: []}
    ]
  }

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

  defp visible(assigns),
    do: for({moment, state} <- Continuous.visible(@journey, assigns), do: {moment.key, state})

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

  # The live action the router gives `path`, which is what a redirect to it
  # mounts with.
  defp live_action(path) do
    %{phoenix_live_view: {_view, action, _opts, _live_session}} =
      Phoenix.Router.route_info(TymeslotWeb.Router, "GET", URI.parse(path).path, "localhost")

    action
  end

  describe "entry/3" do
    test "lands each route on the moment collecting what it presets" do
      assert Continuous.entry(@journey, :overview, %{}) == :intro
      assert Continuous.entry(@journey, :schedule, %{}) == :when
      assert Continuous.entry(@journey, :booking, %{}) == :you
      assert Continuous.entry(@journey, :confirmation, %{}) == :confirmation
      assert Continuous.entry(@journey, :anything_else, %{}) == :intro
    end
  end

  describe "entry points" do
    test "a slug link lands on the calendar, with the meeting type done above it" do
      assert Continuous.entry(@journey, :schedule, chosen()) == :when
      assert visible(chosen()) == [intro: :open, offer: :done, when: :current]
    end

    test "a slug link with a date lands on the calendar, the day chosen and the time still open" do
      assigns = chosen(%{selected_date: "2027-03-10", available_slots: ["9:00 AM", "9:30 AM"]})

      assert Continuous.entry(@journey, :schedule, assigns) == :when
      assert visible(assigns) == [intro: :open, offer: :done, when: :current]
    end

    test "a /book link with a date and time lands on the details, every moment above done" do
      assigns =
        chosen(%{
          selected_date: "2027-03-10",
          selected_time: "9:00 AM",
          available_slots: ["9:00 AM", "9:30 AM"]
        })

      assert Continuous.entry(@journey, :booking, assigns) == :you
      assert visible(assigns) == [intro: :open, offer: :done, when: :done, you: :current]
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

        assert Continuous.entry(@journey, live_action(path), socket.assigns) ==
                 Continuous.entry(@journey, start, socket.assigns)
      end
    end
  end

  describe "visible/2" do
    test "before any choice shows the masthead and the meeting types" do
      assert visible(%{}) == [intro: :open, offer: :current]
    end

    test "once a meeting type without questions is chosen, opens the times below it" do
      assigns = %{
        meeting_types: [meeting_type()],
        meeting_type: meeting_type(),
        selected_duration: "quick-chat",
        selected_date: nil,
        selected_time: nil
      }

      assert visible(assigns) == [intro: :open, offer: :done, when: :current]
    end

    test "shows nothing while an outcome is current" do
      assert visible(chosen(%{current_state: :confirmation})) == []
      assert visible(chosen(%{current_state: :awaiting_payment})) == []
    end
  end

  describe "go_to/3" do
    test "changes nothing: every reached moment is already on the page" do
      socket = %Socket{assigns: %{__changed__: %{}, journey: @journey, current_state: :when}}

      assert Continuous.go_to(@journey, socket, "offer") == {:noreply, socket}
    end
  end

  describe "frame/0" do
    test "is a div" do
      assert {"div", attrs} = Continuous.frame()
      assert attrs[:class] =~ "journey--continuous"
    end
  end
end
