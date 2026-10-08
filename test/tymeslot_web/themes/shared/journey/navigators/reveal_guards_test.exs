defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.RevealGuardsTest do
  @moduledoc """
  The guards a navigator that reveals several moments (`Navigators.Reveal`)
  must keep, through `Journey.Runtime` as `SchedulingLive` drives it: events
  are taken only from a visible moment, nothing moves while a checkout is
  open, and "Schedule another meeting" starts again on the journey's entry.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes
  @moduletag :integration

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.{Continuous, Transcript}
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @intro %{name: "Intro call", slug: "intro-call", duration_minutes: 30}

  @navigators [Continuous, Transcript]

  defp journey(navigator) do
    %Journey{
      navigator: navigator,
      outcomes: %{},
      moments: [
        %Moment{key: :intro, collects: [], component: nil, defaults: []},
        %Moment{key: :offer, collects: [:meeting_type], component: nil, defaults: []},
        %Moment{key: :when, collects: [:slot], component: nil, defaults: []},
        %Moment{key: :you, collects: [:attendee], component: nil, defaults: []}
      ]
    }
  end

  # A booker on the times: the meeting type chosen, no slot yet, every moment
  # reached already open (so settling enters nothing again).
  defp at_times(navigator, assigns \\ %{}) do
    %Socket{
      assigns:
        Map.merge(
          %{
            __changed__: %{},
            flash: %{},
            journey: journey(navigator),
            current_state: :when,
            journey_opened: MapSet.new([:intro, :offer, :when]),
            meeting_type: @intro,
            selected_duration: "intro-call",
            duration: "intro-call",
            selected_date: nil,
            selected_time: nil,
            timezone_dropdown_open: false,
            user_timezone: "Europe/London"
          },
          assigns
        )
    }
  end

  for navigator <- @navigators do
    describe "#{inspect(navigator)}" do
      setup do: %{navigator: unquote(navigator)}

      test "takes the timezone picker's events from a visible moment only", %{navigator: nav} do
        socket = at_times(nav)

        for moment <- [:intro, :offer, :when] do
          assert {:noreply, toggled} =
                   Runtime.handle_step_event(socket, moment, :toggle_timezone_dropdown, nil)

          assert toggled.assigns.timezone_dropdown_open
        end

        assert Runtime.handle_step_event(socket, :you, :toggle_timezone_dropdown, nil) ==
                 :unhandled

        assert Runtime.handle_step_event(socket, nil, :toggle_timezone_dropdown, nil) ==
                 :unhandled
      end

      test "takes no ambient or fact event on an outcome", %{navigator: nav} do
        for outcome <- [:confirmation, :awaiting_payment] do
          socket = at_times(nav, %{current_state: outcome})

          assert Runtime.handle_step_event(socket, outcome, :change_timezone, "Asia/Tokyo") ==
                   :unhandled

          assert Runtime.handle_step_event(socket, :when, :change_timezone, "Asia/Tokyo") ==
                   :unhandled

          assert Runtime.handle_step_event(socket, :when, :select_date, "2027-01-05") ==
                   :unhandled

          assert Runtime.handle_step_event(socket, :offer, :select_duration, "intro-call") ==
                   :unhandled
        end
      end

      test "takes no fact event from a moment not reached yet", %{navigator: nav} do
        assert Runtime.handle_step_event(at_times(nav), :you, :validate, %{}) == :unhandled
      end

      test "takes a meeting type from its answered moment only when it may be revisited",
           %{navigator: nav} do
        direct = at_times(nav, %{entered_via_overview: false})

        assert Runtime.handle_step_event(direct, :offer, :select_duration, "private-call") ==
                 :unhandled

        via_overview = at_times(nav, %{entered_via_overview: true})

        assert {:noreply, changed} =
                 Runtime.handle_step_event(via_overview, :offer, :select_duration, "private-call")

        assert changed.assigns.selected_duration == "private-call"
      end

      test "forgets the time and the details when the answered meeting type changes",
           %{navigator: nav} do
        socket = at_details(%{entered_via_overview: true}, nav)

        assert {:noreply, changed} =
                 Runtime.handle_step_event(socket, :offer, :select_duration, "long-call")

        assert %{
                 current_state: :when,
                 journey_focus: :when,
                 selected_duration: "long-call",
                 selected_date: "2027-01-05",
                 selected_time: nil,
                 submission_token: nil
               } = changed.assigns

        assert changed.assigns.journey_opened == MapSet.new([:intro, :offer, :when])
      end

      test "keeps the time and the details when the same meeting type is chosen again",
           %{navigator: nav} do
        socket = at_details(%{entered_via_overview: true}, nav)

        assert {:noreply, same} =
                 Runtime.handle_step_event(socket, :offer, :select_duration, "intro-call")

        assert %{current_state: :you, selected_time: "10:00", submission_token: "token"} =
                 same.assigns
      end

      test "takes next and back only from the current moment", %{navigator: nav} do
        socket = at_times(nav)

        assert Runtime.handle_step_event(socket, :offer, :next_step, nil) == :unhandled
        assert Runtime.handle_step_event(socket, :intro, :back_step, nil) == :unhandled
      end

      test "moves nothing while a checkout is open", %{navigator: nav} do
        socket =
          at_times(nav, %{
            current_state: :awaiting_payment,
            selected_date: "2027-01-05",
            selected_time: "10:00",
            journey_opened: MapSet.new([:intro, :offer, :when, :you])
          })

        journey = socket.assigns.journey

        assert Runtime.handle_step_event(socket, :awaiting_payment, :next_step, nil) ==
                 :unhandled

        assert Runtime.handle_step_event(socket, :you, :back_step, nil) == :unhandled
        assert nav.continue(journey, socket) == {:noreply, socket}
        assert nav.back(journey, socket) == {:noreply, socket}
        assert Runtime.settle(socket) == socket

        for step <- ["intro", "offer", "when", "you", "1", "confirmation"] do
          assert Runtime.navigate_to_step(socket, %{"step" => step}) == {:noreply, socket}
        end
      end

      test "starts again on the moment still to complete, the slot forgotten", %{navigator: nav} do
        for via_overview <- [true, false] do
          socket =
            at_times(nav, %{
              current_state: :confirmation,
              client_ip: "127.0.0.1",
              entered_via_overview: via_overview,
              selected_date: "2027-01-05",
              selected_time: "10:00",
              meeting_uid: "booked",
              journey_opened: MapSet.new()
            })

          assert {:noreply, restarted} =
                   Runtime.handle_step_event(socket, :confirmation, :schedule_another, nil)

          assert %{
                   current_state: :when,
                   meeting_type: @intro,
                   selected_date: nil,
                   selected_time: nil
                 } = restarted.assigns

          assert restarted.assigns.journey_opened == MapSet.new([:intro, :offer, :when])
        end
      end
    end
  end

  # A booker on the details: the slot chosen, the attendee moment open with
  # its submission token.
  defp at_details(assigns, navigator \\ Transcript) do
    at_times(
      navigator,
      Map.merge(
        %{
          current_state: :you,
          selected_date: "2027-01-05",
          selected_time: "10:00",
          submission_token: "token",
          journey_opened: MapSet.new([:intro, :offer, :when, :you])
        },
        assigns
      )
    )
  end

  defp step(socket, step), do: Runtime.navigate_to_step(socket, %{"step" => step})

  describe "Transcript's Edit" do
    test "forgets the answered moment and every moment after it" do
      assert {:noreply, edited} = step(at_details(%{entered_via_overview: true}), "when")

      assert %{
               current_state: :when,
               journey_focus: :when,
               meeting_type: @intro,
               selected_date: "2027-01-05",
               selected_time: nil,
               submission_token: nil
             } = edited.assigns

      assert edited.assigns.journey_opened == MapSet.new([:intro, :offer, :when])
    end

    test "reopens the meeting type only for a booker who came through the overview" do
      assert {:noreply, edited} = step(at_details(%{entered_via_overview: true}), "offer")
      assert %{current_state: :offer, meeting_type: nil, selected_time: nil} = edited.assigns

      direct = at_details(%{entered_via_overview: false})
      assert step(direct, "offer") == {:noreply, direct}
    end

    test "reaches no outcome, and edits nothing while one is current" do
      socket = at_details(%{entered_via_overview: true})

      for outcome <- ["confirmation", "awaiting_payment", "you", "intro", "nope"] do
        assert step(socket, outcome) == {:noreply, socket}
      end

      for outcome <- [:confirmation, :awaiting_payment] do
        on_outcome = at_details(%{entered_via_overview: true, current_state: outcome})

        for target <- ["offer", "when", "you"] do
          assert step(on_outcome, target) == {:noreply, on_outcome}
        end

        assert Transcript.back(on_outcome.assigns.journey, on_outcome) == {:noreply, on_outcome}
      end
    end

    test "Back from the start of a moment edits the last answered one" do
      socket = at_details(%{entered_via_overview: true})

      assert {:noreply, edited} = Runtime.handle_step_event(socket, :you, :back_step, nil)
      assert %{current_state: :when, selected_time: nil, journey_focus: :when} = edited.assigns
    end

    test "Back changes nothing when no answer may be edited" do
      socket = at_times(Transcript, %{entered_via_overview: false})

      assert Runtime.handle_step_event(socket, :when, :back_step, nil) == {:noreply, socket}
    end
  end
end
