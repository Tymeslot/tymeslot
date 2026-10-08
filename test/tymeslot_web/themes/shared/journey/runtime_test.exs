defmodule TymeslotWeb.Themes.Shared.Journey.RuntimeTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.{
    BookingStep,
    ConfirmationStep,
    OverviewStep,
    QuestionsStep,
    ScheduleStep
  }

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @intro %{name: "Intro call", slug: "intro-call", duration_minutes: 30}

  defp classic do
    Journey.new(
      Journey.classic(%{
        overview: OverviewStep,
        schedule: ScheduleStep,
        questions: QuestionsStep,
        booking: BookingStep,
        confirmation: ConfirmationStep
      })
    )
  end

  defp socket(assigns),
    do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}, journey: classic()}, assigns)}

  defp question(id), do: %{"id" => id, "type" => "short_text", "label" => id, "required" => true}

  describe "transition_to/3" do
    test "showing an outcome only names it" do
      socket = socket(%{current_state: :booking, meeting_uid: "abc"})
      shown = Runtime.transition_to(socket, :confirmation, %{})

      assert shown.assigns.current_state == :confirmation

      assert Map.drop(shown.assigns, [:current_state, :__changed__]) ==
               Map.drop(socket.assigns, [:current_state, :__changed__])
    end

    test "showing a moment runs what its facts set up" do
      socket =
        socket(%{current_state: :schedule, meeting_type: %{custom_fields: [question("company")]}})

      socket = Runtime.transition_to(socket, :questions, %{})

      assert socket.assigns.current_state == :questions
      assert %Engine{} = socket.assigns.engine
      assert Engine.total(socket.assigns.engine) == 1
    end
  end

  describe "handle_step_event/4" do
    test "a fact's event from the moment on screen reaches the fact" do
      socket = socket(%{current_state: :schedule, meeting_type: @intro, selected_time: "09:00"})

      assert {:noreply, socket} =
               Runtime.handle_step_event(socket, :schedule, :select_date, "2027-01-05")

      assert socket.assigns.selected_date == "2027-01-05"
      assert_received {:load_slots, "2027-01-05"}
    end

    # The answers beside the details form: submitting the form is the
    # confirmation, so answers that validate let the form's events through
    # with no Continue of their own.
    test "a moment asking the questions beside the details takes the form's events" do
      journey =
        Journey.new(
          navigator: Journey.Navigators.Paged,
          moments: [
            {:overview, collects: [:meeting_type], component: OverviewStep},
            {:schedule, collects: [:slot], component: ScheduleStep},
            {:booking, collects: [:answers, :attendee], component: BookingStep}
          ],
          outcomes: %{confirmation: ConfirmationStep}
        )

      engine = [question("company")] |> Engine.init() |> Engine.answer("company", "Acme")

      socket =
        socket(%{
          journey: journey,
          current_state: :booking,
          meeting_type: Map.put(@intro, :custom_fields, [question("company")]),
          selected_date: "2027-01-05",
          selected_time: "9:00 AM",
          engine: engine
        })

      assert {:noreply, socket} = Runtime.handle_step_event(socket, :booking, :toggle_guests, nil)
      assert socket.assigns.guests_open

      blank = put_in(socket.assigns.engine, Engine.init([question("company")]))
      assert Runtime.handle_step_event(blank, :booking, :toggle_guests, nil) == :unhandled
    end

    test "a fact's event waits for the facts it needs" do
      socket = socket(%{current_state: :schedule, meeting_types: [@intro]})

      assert Runtime.handle_step_event(socket, :schedule, :select_date, "2027-01-05") ==
               :unhandled
    end

    test "a fact's event is not handled when this booking does not need the fact" do
      socket =
        socket(%{current_state: :questions, meeting_type: %{custom_fields: []}, engine: nil})

      assert Runtime.handle_step_event(socket, :questions, :answer, {"company", "Acme"}) ==
               :unhandled
    end

    test "an event of a moment that is not on screen is not handled" do
      overview = socket(%{current_state: :overview})

      booking =
        socket(%{
          current_state: :booking,
          meeting_type: %{custom_fields: [question("company")]},
          engine: Engine.init([question("company")])
        })

      assert Runtime.handle_step_event(overview, :overview, :select_date, "2030-01-01") ==
               :unhandled

      assert Runtime.handle_step_event(booking, :questions, :answer, {"company", ""}) ==
               :unhandled
    end

    test "an event the flow does not know is left to the theme" do
      assert Runtime.handle_step_event(
               socket(%{current_state: :schedule}),
               :schedule,
               :spin_globe,
               nil
             ) ==
               :unhandled
    end

    test "the timezone picker's events are accepted from any moment on screen" do
      socket = socket(%{current_state: :booking, timezone_dropdown_open: false})

      assert {:noreply, socket} =
               Runtime.handle_step_event(socket, :booking, :toggle_timezone_dropdown, nil)

      assert socket.assigns.timezone_dropdown_open
    end

    test "the timezone picker's events are not taken from an outcome or a moment off screen" do
      confirmation = socket(%{current_state: :confirmation, user_timezone: "Europe/London"})
      schedule = socket(%{current_state: :schedule, user_timezone: "Europe/London"})

      assert Runtime.handle_step_event(
               confirmation,
               :confirmation,
               :change_timezone,
               "Asia/Tokyo"
             ) ==
               :unhandled

      assert Runtime.handle_step_event(schedule, nil, :change_timezone, "Asia/Tokyo") ==
               :unhandled

      assert Runtime.handle_step_event(schedule, :booking, :change_timezone, "Asia/Tokyo") ==
               :unhandled

      assert {:noreply, _socket} =
               Runtime.handle_step_event(schedule, :schedule, :change_timezone, "Europe/London")
    end

    test "nothing is handled on a page without a journey" do
      socket = %Socket{assigns: %{__changed__: %{}, flash: %{}, current_state: :schedule}}

      assert Runtime.handle_step_event(socket, :schedule, :next_step, nil) == :unhandled

      assert Runtime.handle_step_event(socket, :schedule, :change_timezone, "Asia/Tokyo") ==
               :unhandled
    end

    test "next and back from the moment on screen go to the navigator" do
      next = socket(%{current_state: :overview, meeting_types: [@intro]})
      back = socket(%{current_state: :schedule, entered_via_overview: true})

      assert {:noreply, next} = Runtime.handle_step_event(next, :overview, :next_step, nil)
      assert next.assigns.flash["error"]

      assert {:noreply, %{assigns: %{current_state: :overview}}} =
               Runtime.handle_step_event(back, :schedule, :back_step, nil)
    end

    test "next from a moment no longer on screen is not handled" do
      socket = socket(%{current_state: :schedule})

      assert Runtime.handle_step_event(socket, :overview, :next_step, nil) == :unhandled
    end

    test "schedule_another starts again, from the confirmation only" do
      socket =
        socket(%{
          current_state: :confirmation,
          entered_via_overview: true,
          client_ip: "127.0.0.1",
          selected_date: "2027-01-05",
          selected_time: "10:00",
          reschedule_meeting_uid: "abc",
          is_rescheduling: true,
          guest_emails: ["a@b.c"]
        })

      assert {:noreply, restarted} =
               Runtime.handle_step_event(socket, :confirmation, :schedule_another, nil)

      assert %{
               current_state: :overview,
               selected_date: nil,
               selected_time: nil,
               reschedule_meeting_uid: nil,
               is_rescheduling: false,
               guest_emails: []
             } = restarted.assigns

      assert Runtime.handle_step_event(
               socket(%{current_state: :booking}),
               :confirmation,
               :schedule_another,
               nil
             ) == :unhandled
    end
  end

  describe "restart/1" do
    test "returns a booker who came through the overview to it" do
      socket =
        socket(%{
          current_state: :confirmation,
          client_ip: "127.0.0.1",
          entered_via_overview: true,
          meeting_type: @intro,
          selected_duration: "intro-call",
          selected_date: "2027-01-05",
          selected_time: "10:00"
        })

      assert %{current_state: :overview, selected_date: nil, selected_time: nil} =
               Runtime.restart(socket).assigns
    end

    # A private link must never show the organiser's other meeting types, so
    # the booking starts again where that link opens: the schedule of the
    # same type, with a fresh slot.
    test "keeps a booker who came by a direct link on the same meeting type's schedule" do
      socket =
        socket(%{
          current_state: :confirmation,
          client_ip: "127.0.0.1",
          entered_via_overview: false,
          meeting_type: @intro,
          selected_duration: "intro-call",
          selected_date: "2027-01-05",
          selected_time: "10:00",
          guest_emails: ["a@b.c"]
        })

      assert %{
               current_state: :schedule,
               meeting_type: @intro,
               selected_duration: "intro-call",
               selected_date: nil,
               selected_time: nil,
               guest_emails: []
             } = Runtime.restart(socket).assigns
    end
  end

  describe "navigate_to_step/2" do
    test "hands the step to the navigator" do
      socket = socket(%{current_state: :schedule, meeting_type: nil, entered_via_overview: true})

      assert {:noreply, socket} = Runtime.navigate_to_step(socket, %{"step" => "1"})
      assert socket.assigns.current_state == :overview
    end

    test "ignores a step that is not a string" do
      socket = socket(%{current_state: :schedule, meeting_type: nil})

      assert {:noreply, ^socket} = Runtime.navigate_to_step(socket, %{"step" => 1})
      assert {:noreply, ^socket} = Runtime.navigate_to_step(socket, %{})
    end

    test "moves nothing on a page without a journey" do
      socket = %Socket{assigns: %{__changed__: %{}, flash: %{}, current_state: :schedule}}

      assert {:noreply, ^socket} = Runtime.navigate_to_step(socket, %{"step" => "1"})
    end
  end
end
