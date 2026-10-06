defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper
  alias TymeslotWeb.Themes.Shared.Journey

  @moduletag :themes

  defmodule OverridingLive do
    @moduledoc false

    alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
      BookingComponent,
      ConfirmationComponent,
      CustomQuestionsComponent,
      OverviewComponent,
      ScheduleComponent
    }

    alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper

    use TymeslotWeb.Themes.Shared.SchedulingLive,
      wrapper: &Wrapper.quill_wrapper/1,
      steps: %{
        overview: OverviewComponent,
        schedule: ScheduleComponent,
        questions: CustomQuestionsComponent,
        booking: BookingComponent,
        confirmation: ConfirmationComponent
      }

    # Overriding the hook replaces every clause of the default, which is how
    # a theme used to lose the step indicator without any warning.
    defp handle_theme_event("theme_ping", _params, socket),
      do: {:noreply, assign(socket, :theme_pinged, true)}

    defp handle_theme_event(name, params, socket),
      do: {:noreply, assign(socket, :theme_event, {name, params})}
  end

  # The classic journey written out, as a theme with its own journey writes
  # one.
  defmodule JourneyLive do
    @moduledoc false

    alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
      BookingComponent,
      ConfirmationComponent,
      CustomQuestionsComponent,
      OverviewComponent,
      ScheduleComponent
    }

    alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper
    alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

    use TymeslotWeb.Themes.Shared.SchedulingLive,
      wrapper: &Wrapper.quill_wrapper/1,
      journey: [
        navigator: Paged,
        moments: [
          {:overview, collects: [:meeting_type], component: OverviewComponent},
          {:schedule, collects: [:slot], component: ScheduleComponent},
          {:questions, collects: [:answers], component: CustomQuestionsComponent},
          {:booking, collects: [:attendee], component: BookingComponent}
        ],
        outcomes: %{confirmation: ConfirmationComponent, awaiting_payment: :shared}
      ]
  end

  # A theme's own module named `Journey`, holding one of its components.
  defmodule Own.Journey.OverviewComponent do
    @moduledoc false
    use Phoenix.LiveComponent

    @impl Phoenix.LiveComponent
    def render(assigns), do: ~H"<div></div>"
  end

  # Named like an alias `use TymeslotWeb, :live_view` adds to every LiveView.
  defmodule Own.Flash.ScheduleComponent do
    @moduledoc false
    use Phoenix.LiveComponent

    @impl Phoenix.LiveComponent
    def render(assigns), do: ~H"<div></div>"
  end

  # A theme whose own aliases `Journey` and `Flash` are not the ones the
  # generated code knows: its journey must mean the same modules when
  # checked and when built at run time.
  defmodule OwnJourneyLive do
    @moduledoc false

    alias TymeslotWeb.Themes.Quill.Scheduling.Components.{
      BookingComponent,
      ConfirmationComponent,
      CustomQuestionsComponent
    }

    alias TymeslotWeb.Themes.Quill.Scheduling.Wrapper
    alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged
    alias TymeslotWeb.Themes.Shared.SchedulingLiveTest.Own.Flash
    alias TymeslotWeb.Themes.Shared.SchedulingLiveTest.Own.Journey

    use TymeslotWeb.Themes.Shared.SchedulingLive,
      wrapper: &Wrapper.quill_wrapper/1,
      journey: [
        navigator: Paged,
        moments: [
          {:overview, collects: [:meeting_type], component: Journey.OverviewComponent},
          {:schedule, collects: [:slot], component: Flash.ScheduleComponent},
          {:questions, collects: [:answers], component: CustomQuestionsComponent},
          {:booking, collects: [:attendee], component: BookingComponent}
        ],
        outcomes: %{confirmation: ConfirmationComponent}
      ]
  end

  defp socket(assigns) do
    %Socket{
      assigns:
        Map.merge(%{__changed__: %{}, flash: %{}, journey: OverridingLive.__journey__()}, assigns)
    }
  end

  describe "a theme with its own events" do
    test "still lets the booker go back through the step indicator" do
      # A booker who came through the overview: only they may return to it.
      socket =
        socket(%{current_state: :schedule, meeting_type: nil, entered_via_overview: true})

      assert {:noreply, socket} =
               OverridingLive.handle_event("navigate_to_step", %{"step" => "1"}, socket)

      assert socket.assigns.current_state == :overview
    end

    test "still receives its own events" do
      assert {:noreply, socket} =
               OverridingLive.handle_event("theme_ping", %{}, socket(%{current_state: :overview}))

      assert socket.assigns.theme_pinged
    end
  end

  describe "a theme's own step events" do
    test "reach handle_theme_event/3 without their prefix" do
      assert {:noreply, socket} =
               OverridingLive.handle_info(
                 {:step_event, :booking, "theme:flip", %{"card" => "3"}},
                 socket(%{current_state: :booking})
               )

      assert socket.assigns.theme_event == {"flip", %{"card" => "3"}}
    end

    test "reach handle_theme_event/3 from the schedule step too" do
      assert {:noreply, socket} =
               OverridingLive.handle_info(
                 {:step_event, :schedule, "theme:flip", %{"card" => "3"}},
                 socket(%{current_state: :schedule})
               )

      assert socket.assigns.theme_event == {"flip", %{"card" => "3"}}
    end

    test "cannot pose as a canonical event" do
      socket = socket(%{current_state: :schedule, timezone_dropdown_open: false})

      assert {:noreply, socket} =
               OverridingLive.handle_info(
                 {:step_event, :schedule, "theme:toggle_timezone_dropdown", %{}},
                 socket
               )

      assert socket.assigns.theme_event == {"toggle_timezone_dropdown", %{}}
      refute socket.assigns.timezone_dropdown_open
    end

    test "leave canonical events to the flow" do
      socket = socket(%{current_state: :schedule, timezone_dropdown_open: false})

      assert {:noreply, socket} =
               OverridingLive.handle_info(
                 {:step_event, :schedule, :toggle_timezone_dropdown, nil},
                 socket
               )

      assert socket.assigns.timezone_dropdown_open
      refute Map.has_key?(socket.assigns, :theme_event)
    end

    test "a canonical event the schedule step declines reaches no theme hook" do
      socket = socket(%{current_state: :schedule})

      assert {:noreply, socket} =
               OverridingLive.handle_info(
                 {:step_event, :schedule, :select_duration, "30"},
                 socket
               )

      refute Map.has_key?(socket.assigns, :theme_event)
    end

    test "sent to the LiveView itself also lose their prefix" do
      assert {:noreply, socket} =
               OverridingLive.handle_event("theme:flip", %{}, socket(%{current_state: :overview}))

      assert socket.assigns.theme_event == {"flip", %{}}
    end
  end

  describe "a message the flow does not route" do
    test "is ignored, leaving the page as it was" do
      socket = socket(%{current_state: :overview})

      assert {:noreply, ^socket} =
               OverridingLive.handle_info({:no_such_message, make_ref()}, socket)
    end
  end

  describe "use SchedulingLive" do
    test "refuses a theme that leaves out a step component" do
      assert_raise ArgumentError, ~r/missing.*:confirmation/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.MissingStepLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                steps: %{
                  overview: TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
                  schedule: TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
                  questions:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
                  booking: TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent
                }
            end
          end
        )
      end
    end

    test "refuses a step it does not know" do
      assert_raise ArgumentError, ~r/does not know.*:awaiting_payment/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.UnknownStepLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                steps: %{
                  overview: TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
                  schedule: TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
                  questions:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
                  booking: TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent,
                  confirmation:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent,
                  awaiting_payment:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent
                }
            end
          end
        )
      end
    end

    test "refuses a step that is not a LiveComponent" do
      assert_raise CompileError,
                   ~r/step :confirmation.*TymeslotWeb\.Themes\.Quill\.Scheduling\.Live\b/,
                   fn ->
                     Code.compile_quoted(
                       quote do
                         defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.LiveViewStepLive do
                           use TymeslotWeb.Themes.Shared.SchedulingLive,
                             wrapper: &Wrapper.quill_wrapper/1,
                             steps: %{
                               overview:
                                 TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
                               schedule:
                                 TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
                               questions:
                                 TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
                               booking:
                                 TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent,
                               confirmation: TymeslotWeb.Themes.Quill.Scheduling.Live
                             }
                         end
                       end
                     )
                   end
    end

    test "refuses a step component that does not exist" do
      assert_raise CompileError, ~r/step :booking.*NoSuchComponent/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.MissingModuleLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                steps: %{
                  overview: TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
                  schedule: TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
                  questions:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
                  booking: TymeslotWeb.Themes.Quill.Scheduling.Components.NoSuchComponent,
                  confirmation:
                    TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent
                }
            end
          end
        )
      end
    end

    test "refuses the retired theme_id option" do
      assert_raise ArgumentError, ~r/theme_id/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.ThemeIdLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive, theme_id: "1"
            end
          end
        )
      end
    end

    test "expands steps: to the classic journey" do
      steps = %{
        overview: TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent,
        schedule: TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent,
        questions: TymeslotWeb.Themes.Quill.Scheduling.Components.CustomQuestionsComponent,
        booking: TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent,
        confirmation: TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent
      }

      assert OverridingLive.__journey__() == Journey.new(Journey.classic(steps))
    end

    test "takes a journey written out, the classic one included" do
      assert JourneyLive.__journey__() == OverridingLive.__journey__()
    end

    test "builds a journey with the theme's own aliases, as it was checked" do
      journey = OwnJourneyLive.__journey__()

      assert Journey.moment(journey, :overview).component ==
               TymeslotWeb.Themes.Shared.SchedulingLiveTest.Own.Journey.OverviewComponent

      assert Journey.moment(journey, :schedule).component ==
               TymeslotWeb.Themes.Shared.SchedulingLiveTest.Own.Flash.ScheduleComponent
    end

    test "refuses both steps: and journey:" do
      assert_raise ArgumentError, ~r/not both/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.BothLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                steps: %{},
                journey: []
            end
          end
        )
      end
    end

    test "refuses a theme with neither" do
      assert_raise ArgumentError, ~r/needs :steps .* or :journey/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.NeitherLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive, wrapper: &Wrapper.quill_wrapper/1
            end
          end
        )
      end
    end

    test "refuses a journey that is not literal data" do
      assert_raise ArgumentError, ~r/literal data/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.ComputedLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                journey: Journey.classic(%{})
            end
          end
        )
      end
    end

    test "refuses a journey that asks for the slot before the meeting type" do
      assert_raise CompileError, ~r/collects :slot, which needs :meeting_type/, fn ->
        Code.compile_quoted(
          quote do
            defmodule TymeslotWeb.Themes.Shared.SchedulingLiveTest.SlotFirstLive do
              use TymeslotWeb.Themes.Shared.SchedulingLive,
                wrapper: &Wrapper.quill_wrapper/1,
                journey: [
                  navigator: TymeslotWeb.Themes.Shared.Journey.Navigators.Paged,
                  moments: [
                    {:schedule,
                     collects: [:slot],
                     component: TymeslotWeb.Themes.Quill.Scheduling.Components.ScheduleComponent},
                    {:overview,
                     collects: [:meeting_type],
                     component: TymeslotWeb.Themes.Quill.Scheduling.Components.OverviewComponent},
                    {:booking,
                     collects: [:attendee],
                     component: TymeslotWeb.Themes.Quill.Scheduling.Components.BookingComponent}
                  ],
                  outcomes: %{
                    confirmation:
                      TymeslotWeb.Themes.Quill.Scheduling.Components.ConfirmationComponent
                  }
                ]
            end
          end
        )
      end
    end
  end
end
