defmodule TymeslotWeb.Themes.Shared.Journey.Navigators.PagedTest do
  use Tymeslot.DataCase, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.{
    BookingStep,
    ConfirmationStep,
    OverviewStep,
    QuestionsStep,
    ScheduleStep
  }

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Engine
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

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

  defp with_questions(ids), do: %{custom_fields: Enum.map(ids, &question/1)}

  describe "entry/3" do
    test "opens each route on the moment collecting what it names" do
      for {action, key} <- [
            overview: :overview,
            schedule: :schedule,
            booking: :booking,
            confirmation: :confirmation,
            cancel: :overview
          ] do
        assert Paged.entry(classic(), action, %{}) == key
      end
    end

    test "opens a time-first journey's schedule route on the moment collecting the slot" do
      journey =
        Journey.new(
          navigator: Paged,
          moments: [
            {:now, collects: [:meeting_type, :slot], component: ScheduleStep},
            {:you, collects: [:attendee], component: BookingStep}
          ],
          outcomes: %{confirmation: ConfirmationStep}
        )

      assert Paged.entry(journey, :schedule, %{}) == :now
      assert Paged.entry(journey, :booking, %{}) == :you
    end
  end

  describe "visible/2" do
    test "is the current moment alone" do
      assert [{%{key: :schedule}, :current}] =
               Paged.visible(classic(), %{current_state: :schedule})
    end

    test "is the first moment for a state the journey does not know" do
      assert [{%{key: :overview}, :current}] = Paged.visible(classic(), %{current_state: nil})
    end

    test "is nothing while an outcome is shown" do
      assert Paged.visible(classic(), %{current_state: :confirmation}) == []
      assert Paged.visible(classic(), %{current_state: :awaiting_payment}) == []
    end
  end

  describe "continue/2" do
    test "says why the booker cannot leave the overview yet, and stays" do
      socket = socket(%{current_state: :overview, meeting_types: [@intro]})

      assert {:noreply, socket} = Paged.continue(classic(), socket)

      assert socket.assigns.current_state == :overview
      assert socket.assigns.flash["error"] == BookingErrorMessage.message(:duration_required)
    end

    test "moves from the overview to the schedule once a type is chosen" do
      socket =
        socket(%{
          current_state: :overview,
          meeting_types: [@intro],
          selected_duration: "intro-call"
        })

      assert {:noreply, socket} = Paged.continue(classic(), socket)
      assert socket.assigns.current_state == :schedule
    end

    test "moves from the schedule to the questions when the meeting type has them" do
      socket =
        socket(%{
          current_state: :schedule,
          meeting_type: with_questions(["company"]),
          selected_date: "2027-01-05",
          selected_time: "10:00",
          available_slots: []
        })

      assert {:noreply, socket} = Paged.continue(classic(), socket)

      assert socket.assigns.current_state == :questions
      assert Engine.total(socket.assigns.engine) == 1
    end

    test "moves from the schedule straight to the booking when the meeting type has no questions" do
      socket =
        socket(%{
          current_state: :schedule,
          meeting_type: %{custom_fields: []},
          selected_date: "2027-01-05",
          selected_time: "10:00",
          available_slots: []
        })

      assert {:noreply, socket} = Paged.continue(classic(), socket)
      assert socket.assigns.current_state == :booking
    end

    test "says which half of the slot is missing, and stays" do
      socket =
        socket(%{
          current_state: :schedule,
          selected_date: "2027-01-05",
          selected_time: nil,
          available_slots: []
        })

      assert {:noreply, socket} = Paged.continue(classic(), socket)

      assert socket.assigns.current_state == :schedule
      assert socket.assigns.flash["error"] == BookingErrorMessage.message(:time_required)
    end

    test "moves within the questions before leaving them" do
      engine =
        [question("company"), question("role")]
        |> Engine.init()
        |> Engine.answer("company", "Acme")

      socket =
        socket(%{
          current_state: :questions,
          meeting_type: with_questions(["company", "role"]),
          engine: engine
        })

      assert {:noreply, socket} = Paged.continue(classic(), socket)

      assert socket.assigns.engine.current_index == 1
      assert socket.assigns.current_state == :questions
    end

    test "on an outcome moves nothing" do
      socket = socket(%{current_state: :confirmation})

      assert Paged.continue(classic(), socket) == {:noreply, socket}
    end
  end

  describe "back/2" do
    test "is refused to a booker who never saw the overview" do
      socket = socket(%{current_state: :schedule, entered_via_overview: false})

      assert {:noreply, socket} = Paged.back(classic(), socket)
      assert socket.assigns.current_state == :schedule
    end

    test "returns to the overview for a booker who came through it" do
      socket = socket(%{current_state: :schedule, entered_via_overview: true})

      assert {:noreply, socket} = Paged.back(classic(), socket)
      assert socket.assigns.current_state == :overview
    end

    test "from the first question returns to the schedule" do
      socket =
        socket(%{
          current_state: :questions,
          meeting_type: with_questions(["company"]),
          engine: Engine.init([question("company")])
        })

      assert {:noreply, socket} = Paged.back(classic(), socket)
      assert socket.assigns.current_state == :schedule
    end

    test "from a later question returns to the one before" do
      engine =
        [question("company"), question("role")]
        |> Engine.init()
        |> Engine.answer("company", "Acme")

      {:ok, engine} = Engine.next(engine)

      socket =
        socket(%{
          current_state: :questions,
          meeting_type: with_questions(["company", "role"]),
          engine: engine
        })

      assert {:noreply, socket} = Paged.back(classic(), socket)

      assert socket.assigns.current_state == :questions
      assert socket.assigns.engine.current_index == 0
    end

    test "from the booking returns to the questions when the meeting type has them" do
      socket = socket(%{current_state: :booking, meeting_type: with_questions(["company"])})

      assert {:noreply, socket} = Paged.back(classic(), socket)
      assert socket.assigns.current_state == :questions
    end

    test "from the booking returns to the schedule when the meeting type has no questions" do
      socket = socket(%{current_state: :booking, meeting_type: %{custom_fields: []}})

      assert {:noreply, socket} = Paged.back(classic(), socket)
      assert socket.assigns.current_state == :schedule
    end
  end

  describe "go_to/3" do
    test "moves back to an earlier step" do
      socket = socket(%{current_state: :schedule, meeting_type: nil, entered_via_overview: true})

      assert {:noreply, socket} = Paged.go_to(classic(), socket, "1")
      assert socket.assigns.current_state == :overview
    end

    test "never skips ahead to a step the booker has not reached" do
      socket = socket(%{current_state: :overview, meeting_type: nil})

      assert {:noreply, socket} = Paged.go_to(classic(), socket, "3")
      assert socket.assigns.current_state == :overview
    end

    test "numbers the questions only when the meeting type has them" do
      with_fields = socket(%{current_state: :booking, meeting_type: with_questions(["company"])})

      without =
        socket(%{
          current_state: :booking,
          meeting_type: %{custom_fields: []},
          entered_via_overview: true
        })

      assert {:noreply, %{assigns: %{current_state: :questions}}} =
               Paged.go_to(classic(), with_fields, "3")

      assert {:noreply, %{assigns: %{current_state: :booking}}} =
               Paged.go_to(classic(), without, "3")

      assert {:noreply, %{assigns: %{current_state: :overview}}} =
               Paged.go_to(classic(), without, "1")
    end

    test "from an outcome moves back to any moment, never to an outcome" do
      socket =
        socket(%{current_state: :confirmation, meeting_type: nil, entered_via_overview: true})

      assert {:noreply, %{assigns: %{current_state: :overview}}} =
               Paged.go_to(classic(), socket, "1")

      assert {:noreply, ^socket} = Paged.go_to(classic(), socket, "4")
    end

    test "moves nowhere while the booker waits on an open checkout" do
      socket =
        socket(%{
          current_state: :awaiting_payment,
          meeting_type: %{custom_fields: []},
          entered_via_overview: true
        })

      for step <- ["1", "2", "3"] do
        assert {:noreply, ^socket} = Paged.go_to(classic(), socket, step)
      end
    end

    test "never returns to the overview a booker who came by a direct link" do
      socket = socket(%{current_state: :schedule, meeting_type: nil, entered_via_overview: false})

      assert {:noreply, ^socket} = Paged.go_to(classic(), socket, "1")
    end

    test "returns to the overview a booker who came through it" do
      socket = socket(%{current_state: :booking, meeting_type: nil, entered_via_overview: true})

      assert {:noreply, %{assigns: %{current_state: :overview}}} =
               Paged.go_to(classic(), socket, "1")
    end

    test "ignores a step that is not a number" do
      socket = socket(%{current_state: :schedule})

      assert {:noreply, ^socket} = Paged.go_to(classic(), socket, "first")
    end
  end
end
