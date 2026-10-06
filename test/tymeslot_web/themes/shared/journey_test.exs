defmodule TymeslotWeb.Themes.Shared.JourneyTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias TymeslotWeb.Test.FixtureTheme.Scheduling.{
    BookingStep,
    ConfirmationStep,
    OverviewStep,
    QuestionsStep,
    ScheduleStep
  }

  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Facts.{Answers, Attendee, MeetingType, Slot}
  alias TymeslotWeb.Themes.Shared.Journey.Moment

  # A navigator with every callback and no behaviour, so the checks can be
  # tested apart from any shipped navigator.
  defmodule StillNavigator do
    @moduledoc false
    @behaviour TymeslotWeb.Themes.Shared.Journey.Navigator

    alias TymeslotWeb.Themes.Shared.Journey.Navigator

    @impl Navigator
    def entry(journey, _live_action, _assigns), do: hd(journey.moments).key

    @impl Navigator
    def visible(journey, _assigns), do: [{hd(journey.moments), :current}]

    @impl Navigator
    def continue(_journey, socket), do: {:noreply, socket}

    @impl Navigator
    def back(_journey, socket), do: {:noreply, socket}

    @impl Navigator
    def go_to(_journey, socket, _step), do: {:noreply, socket}
  end

  # A fact no shipped journey has, and one claiming a shipped key.
  defmodule SeatFact do
    @moduledoc false
    use TymeslotWeb.Themes.Shared.Journey.Fact

    alias TymeslotWeb.Themes.Shared.Journey.Fact

    @impl Fact
    def key, do: :seat
    @impl Fact
    def requires(_assigns), do: [:slot]
    @impl Fact
    def required?(_assigns), do: true
    @impl Fact
    def known?(assigns), do: is_integer(assigns[:seat])
    @impl Fact
    def events, do: []
    @impl Fact
    def handle(socket, _event, _data), do: {:noreply, socket}
  end

  defmodule ClashingFact do
    @moduledoc false
    use TymeslotWeb.Themes.Shared.Journey.Fact

    alias TymeslotWeb.Themes.Shared.Journey.Fact

    @impl Fact
    def key, do: :slot
    @impl Fact
    def requires(_assigns), do: []
    @impl Fact
    def required?(_assigns), do: true
    @impl Fact
    def known?(assigns), do: Map.has_key?(assigns, :slot)
    @impl Fact
    def events, do: []
    @impl Fact
    def handle(socket, _event, _data), do: {:noreply, socket}
  end

  @steps %{
    overview: OverviewStep,
    schedule: ScheduleStep,
    questions: QuestionsStep,
    booking: BookingStep,
    confirmation: ConfirmationStep
  }

  defp journey(moments, outcomes \\ %{confirmation: ConfirmationStep}),
    do: [navigator: StillNavigator, moments: moments, outcomes: outcomes]

  defp build!(opts), do: Journey.build!(opts, __ENV__)

  # Questions before the calendar: legal, since answers need only the type.
  defp questions_first do
    journey([
      {:offer, collects: [:meeting_type], component: OverviewStep},
      {:ask, collects: [:answers], component: QuestionsStep},
      {:when, collects: [:slot], component: ScheduleStep},
      {:you, collects: [:attendee], component: BookingStep}
    ])
  end

  describe "facts/0" do
    test "holds the four shipped facts by key" do
      assert Journey.facts() == %{
               meeting_type: MeetingType,
               slot: Slot,
               answers: Answers,
               attendee: Attendee
             }

      assert Journey.fact!(:slot) == Slot
    end

    test "adds an extra fact under its own key" do
      assert Journey.merge_facts!(Journey.facts(), [SeatFact])[:seat] == SeatFact
    end

    test "refuses an extra fact that claims a shipped key" do
      assert_raise ArgumentError, ~r/ClashingFact.*:slot/, fn ->
        Journey.merge_facts!(Journey.facts(), [ClashingFact])
      end
    end
  end

  describe "classic/1" do
    test "is today's five steps as the paged classic journey" do
      assert Journey.classic(@steps) == [
               navigator: Journey.Navigators.Paged,
               moments: [
                 {:overview, collects: [:meeting_type], component: OverviewStep},
                 {:schedule, collects: [:slot], component: ScheduleStep},
                 {:questions, collects: [:answers], component: QuestionsStep},
                 {:booking, collects: [:attendee], component: BookingStep}
               ],
               outcomes: %{confirmation: ConfirmationStep, awaiting_payment: :shared}
             ]
    end
  end

  describe "new/1 and moment/2" do
    test "turns each moment entry into a Moment, and the payment wait defaults to the shared one" do
      journey = Journey.new(questions_first())

      assert [%Moment{key: :offer, collects: [:meeting_type], defaults: []} | _rest] =
               journey.moments

      assert journey.outcomes == %{confirmation: ConfirmationStep, awaiting_payment: :shared}
      assert %Moment{component: ScheduleStep} = Journey.moment(journey, :when)
      assert Journey.moment(journey, :confirmation) == nil
    end

    test "required_facts/2 leaves out what this booking does not need" do
      journey = Journey.new(questions_first())
      ask = Journey.moment(journey, :ask)

      assert Journey.required_facts(ask, %{meeting_type: %{custom_fields: []}}) == []

      assert Journey.required_facts(ask, %{meeting_type: %{custom_fields: [%{"id" => "q"}]}}) ==
               [Answers]
    end
  end

  describe "build!/2" do
    test "builds a journey that asks the questions before the calendar" do
      assert %Journey{navigator: StillNavigator} = build!(questions_first())
    end

    test "builds a time-first moment collecting the type and the slot together, with a default" do
      assert %Journey{} =
               build!(
                 journey([
                   {:now,
                    collects: [:meeting_type, :slot],
                    component: ScheduleStep,
                    defaults: [meeting_type: :first]},
                   {:you, collects: [:answers, :attendee], component: BookingStep}
                 ])
               )
    end

    test "refuses a fact it does not know" do
      assert_raise CompileError, ~r/moment :when collects :seat, which is no known fact/, fn ->
        questions_first()
        |> Keyword.update!(:moments, fn moments ->
          List.replace_at(moments, 2, {:when, collects: [:seat, :slot], component: ScheduleStep})
        end)
        |> build!()
      end
    end

    test "refuses a slot asked before the meeting type" do
      assert_raise CompileError,
                   ~r/moment :when collects :slot, which needs :meeting_type collected before it/,
                   fn ->
                     build!(
                       journey([
                         {:when, collects: [:slot], component: ScheduleStep},
                         {:offer, collects: [:meeting_type], component: OverviewStep},
                         {:you, collects: [:attendee], component: BookingStep}
                       ])
                     )
                   end
    end

    test "refuses the attendee asked before the answers" do
      assert_raise CompileError,
                   ~r/moment :you collects :attendee, which needs :answers collected before it/,
                   fn ->
                     build!(
                       journey([
                         {:offer, collects: [:meeting_type], component: OverviewStep},
                         {:when, collects: [:slot], component: ScheduleStep},
                         {:you, collects: [:attendee], component: BookingStep},
                         {:ask, collects: [:answers], component: QuestionsStep}
                       ])
                     )
                   end
    end

    test "refuses a fact collected twice" do
      assert_raise CompileError, ~r/fact :slot is collected twice/, fn ->
        build!(
          journey([
            {:offer, collects: [:meeting_type], component: OverviewStep},
            {:when, collects: [:slot], component: ScheduleStep},
            {:again, collects: [:slot], component: ScheduleStep},
            {:you, collects: [:attendee], component: BookingStep}
          ])
        )
      end
    end

    test "refuses a journey no moment of which collects the attendee" do
      assert_raise CompileError, ~r/no moment collects :attendee/, fn ->
        build!(
          journey([
            {:offer, collects: [:meeting_type], component: OverviewStep},
            {:when, collects: [:slot], component: ScheduleStep}
          ])
        )
      end
    end

    test "refuses a moment or an outcome that is not a LiveComponent" do
      assert_raise CompileError,
                   ~r/moment :you needs a LiveComponent, got TymeslotWeb.Themes.Shared.Journey,/,
                   fn ->
                     build!(
                       journey([
                         {:offer, collects: [:meeting_type], component: OverviewStep},
                         {:when, collects: [:slot], component: ScheduleStep},
                         {:you, collects: [:attendee], component: Journey}
                       ])
                     )
                   end

      assert_raise CompileError, ~r/outcome :confirmation needs a LiveComponent, got nil/, fn ->
        build!(Keyword.put(questions_first(), :outcomes, %{awaiting_payment: :shared}))
      end
    end

    test "refuses a default for a fact the moment does not collect" do
      assert_raise CompileError,
                   ~r/moment :when defaults :meeting_type, which it does not collect/,
                   fn ->
                     questions_first()
                     |> Keyword.update!(:moments, fn moments ->
                       List.replace_at(
                         moments,
                         2,
                         {:when,
                          collects: [:slot],
                          component: ScheduleStep,
                          defaults: [meeting_type: :first]}
                       )
                     end)
                     |> build!()
                   end
    end

    test "refuses a default strategy the fact does not take" do
      assert_raise CompileError,
                   ~r/defaults :meeting_type with :latest, which .*MeetingType does not take/,
                   fn ->
                     questions_first()
                     |> Keyword.update!(:moments, fn moments ->
                       List.replace_at(
                         moments,
                         0,
                         {:offer,
                          collects: [:meeting_type],
                          component: OverviewStep,
                          defaults: [meeting_type: :latest]}
                       )
                     end)
                     |> build!()
                   end
    end

    test "refuses a navigator that is not one" do
      assert_raise CompileError, ~r/navigator NoSuchNavigator is not a loaded module/, fn ->
        build!(Keyword.put(questions_first(), :navigator, NoSuchNavigator))
      end
    end

    test "refuses a moment key used twice or named like an outcome" do
      assert_raise CompileError,
                   ~r/moment key :when is used twice.*moment :confirmation has an outcome's name/,
                   fn ->
                     questions_first()
                     |> Keyword.update!(
                       :moments,
                       &(&1 ++
                           [
                             {:when, collects: [], component: ScheduleStep},
                             {:confirmation, collects: [], component: ConfirmationStep}
                           ])
                     )
                     |> build!()
                   end
    end

    test "refuses a malformed moment" do
      assert_raise CompileError, ~r/the journey is malformed/, fn ->
        build!(journey([{:you, component: BookingStep}]))
      end
    end
  end

  test "live_component?/1 knows a loaded LiveComponent" do
    assert Journey.live_component?(OverviewStep)
    refute Journey.live_component?(Journey)
    refute Journey.live_component?(nil)
  end
end
