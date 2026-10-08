defmodule TymeslotWeb.Themes.Shared.Journey.ProgressTest do
  @moduledoc """
  Which moments of a journey a booking has reached, on stub facts so the
  rules are pinned apart from what the shipped facts read: `:a` needs
  nothing, `:b` needs `:a`, `:q` needs `:a` and is required only when the
  assigns say so (like the questions of a meeting type that has some), and
  `:c` needs `:b`, plus `:q` when `:q` is required (like the attendee).
  A fact is known when its key is in `assigns.known`.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Fact
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Progress

  defmodule A do
    @moduledoc false
    use TymeslotWeb.Themes.Shared.Journey.Fact

    @impl Fact
    def key, do: :a
    @impl Fact
    def requires(_assigns), do: []
    @impl Fact
    def required?(_assigns), do: true
    @impl Fact
    def known?(assigns), do: :a in Map.get(assigns, :known, [])
    @impl Fact
    def events, do: []
    @impl Fact
    def handle(socket, _event, _data), do: {:noreply, socket}
  end

  defmodule B do
    @moduledoc false
    use TymeslotWeb.Themes.Shared.Journey.Fact

    @impl Fact
    def key, do: :b
    @impl Fact
    def requires(_assigns), do: [:a]
    @impl Fact
    def required?(_assigns), do: true
    @impl Fact
    def known?(assigns), do: :b in Map.get(assigns, :known, [])
    @impl Fact
    def events, do: []
    @impl Fact
    def handle(socket, _event, _data), do: {:noreply, socket}
  end

  defmodule Q do
    @moduledoc false
    use TymeslotWeb.Themes.Shared.Journey.Fact

    @impl Fact
    def key, do: :q
    @impl Fact
    def requires(_assigns), do: [:a]
    @impl Fact
    def required?(assigns), do: Map.get(assigns, :q_required, false)
    @impl Fact
    def known?(assigns), do: :q in Map.get(assigns, :known, [])
    @impl Fact
    def events, do: []
    @impl Fact
    def handle(socket, _event, _data), do: {:noreply, socket}
  end

  defmodule C do
    @moduledoc false
    use TymeslotWeb.Themes.Shared.Journey.Fact

    @impl Fact
    def key, do: :c
    @impl Fact
    def requires(assigns), do: if(Map.get(assigns, :q_required, false), do: [:b, :q], else: [:b])
    @impl Fact
    def required?(_assigns), do: true
    @impl Fact
    def known?(assigns), do: :c in Map.get(assigns, :known, [])
    @impl Fact
    def events, do: []
    @impl Fact
    def handle(socket, _event, _data), do: {:noreply, socket}
  end

  @facts %{a: A, b: B, c: C, q: Q}

  # Questions first: `ask` collects `:q` before `pick_time` collects `:b`.
  @journey %Journey{
    navigator: nil,
    outcomes: %{},
    moments: [
      %Moment{key: :intro, collects: [], component: nil, defaults: []},
      %Moment{key: :pick, collects: [:a], component: nil, defaults: []},
      %Moment{key: :ask, collects: [:q], component: nil, defaults: []},
      %Moment{key: :pick_time, collects: [:b], component: nil, defaults: []},
      %Moment{key: :you, collects: [:c], component: nil, defaults: []}
    ]
  }

  defp states(assigns),
    do:
      for({moment, state} <- Progress.reached(@journey, assigns, @facts), do: {moment.key, state})

  describe "reached/3" do
    test "with nothing known, the factless moment is open and the first with a fact is current" do
      assert states(%{known: []}) == [intro: :open, pick: :current]
    end

    test "passes over a moment whose facts this booking does not require" do
      assert states(%{known: [:a]}) == [intro: :open, pick: :done, pick_time: :current]
    end

    test "reaches a moment once the booking requires what it collects" do
      assert states(%{known: [:a], q_required: true}) ==
               [intro: :open, pick: :done, ask: :current]
    end

    test "marks every moment done once every fact is known, and none current" do
      assert states(%{known: [:a, :b, :c]}) ==
               [intro: :open, pick: :done, pick_time: :done, you: :done]

      assert Progress.current(@journey, %{known: [:a, :b, :c]}, @facts) == nil
    end
  end

  describe "current/3" do
    test "is the first moment with a required fact still unknown" do
      assert %Moment{key: :you} = Progress.current(@journey, %{known: [:a, :b]}, @facts)
    end
  end

  describe "required/3" do
    test "keeps the collected facts this booking requires" do
      [_intro, _pick, ask | _rest] = @journey.moments

      assert Progress.required(ask, %{q_required: true}, @facts) == [:q]
      assert Progress.required(ask, %{}, @facts) == []
    end
  end

  describe "moment_for/2" do
    test "names the first moment collecting a fact, or nil" do
      assert Progress.moment_for(@journey, :b) == :pick_time
      assert Progress.moment_for(@journey, :nowhere) == nil
    end
  end

  describe "dependents/3" do
    test "is the fact and every fact requiring it, transitively" do
      assert Enum.sort(Progress.dependents(:a, %{}, @facts)) == [:a, :b, :c, :q]
    end

    test "follows what this booking requires" do
      assert Enum.sort(Progress.dependents(:q, %{q_required: true}, @facts)) == [:c, :q]
      assert Progress.dependents(:q, %{}, @facts) == [:q]
    end
  end

  describe "collecting_now?/2" do
    test "asks whether the moment on screen collects the fact" do
      assert Progress.collecting_now?(%{journey: @journey, current_state: :pick_time}, :b)
      refute Progress.collecting_now?(%{journey: @journey, current_state: :pick}, :b)
    end

    test "is false on an outcome and without a journey" do
      refute Progress.collecting_now?(%{journey: @journey, current_state: :confirmation}, :b)
      refute Progress.collecting_now?(%{current_state: :pick_time}, :b)
    end
  end

  describe "at_or_before?/2" do
    test "holds up to and including the first moment collecting the fact" do
      assert Progress.at_or_before?(%{journey: @journey, current_state: :pick}, :b)
      assert Progress.at_or_before?(%{journey: @journey, current_state: :pick_time}, :b)
      refute Progress.at_or_before?(%{journey: @journey, current_state: :you}, :b)
    end

    test "holds before any moment is on screen, and not on an outcome" do
      assert Progress.at_or_before?(%{journey: @journey, current_state: nil}, :b)
      refute Progress.at_or_before?(%{journey: @journey, current_state: :confirmation}, :b)
    end
  end
end
