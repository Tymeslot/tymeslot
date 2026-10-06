defmodule TymeslotWeb.Themes.Shared.Journey do
  @moduledoc """
  A theme's booking journey: how it groups the facts a booking needs
  (`Journey.Fact`) into moments, which navigator (`Journey.Navigator`) shows
  them, and which components show the outcomes.

  A moment (`Journey.Moment`) is a LiveComponent the theme writes, collecting
  zero or more facts, and may settle a fact it collects without asking
  (`defaults:`, checked now and applied once the runtime opens moments).
  Outcomes are where a submit ends, not moments: the
  confirmation, and the wait for an embedded payment, `:shared` meaning
  `Shared.Components.AwaitingPayment`.

  A theme declares its journey on `use SchedulingLive` (`journey:`), or names
  one component per classic step (`steps:`), which `classic/1` expands.
  `build!/2` checks either while the theme compiles; at run time the theme
  builds the same literal with `new/1`.

  The facts are `facts/0`: the four shipped ones, plus any fact module listed
  in `config :tymeslot, :extra_booking_facts` (read at compile time; empty in
  every shipped build).
  """

  alias TymeslotWeb.Themes.Shared.Journey.Facts.{Answers, Attendee, MeetingType, Slot}
  alias TymeslotWeb.Themes.Shared.Journey.Moment
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged

  @enforce_keys [:navigator, :moments, :outcomes]
  defstruct [:navigator, :moments, :outcomes]

  @type outcomes :: %{
          required(:confirmation) => module(),
          required(:awaiting_payment) => module() | :shared
        }

  @type t :: %__MODULE__{navigator: module(), moments: [Moment.t()], outcomes: outcomes()}

  # Plain atoms from config, read at compile time, so they add no
  # compile-time dependency.
  @extra_facts Application.compile_env(:tymeslot, :extra_booking_facts, [])

  @always_collected [:meeting_type, :slot, :attendee]
  @outcome_keys [:confirmation, :awaiting_payment]
  @navigator_callbacks [entry: 3, visible: 2, continue: 2, back: 2, go_to: 3]

  @doc "The fact modules by key: the shipped four and `:extra_booking_facts`."
  @spec facts() :: %{atom() => module()}
  def facts, do: merge_facts!(shipped_facts(), @extra_facts)

  # In a function body, so the fact modules are runtime references of this
  # module. That keeps them off a theme's compile-connected graph only while
  # the theme reaches `Journey` without a compile-time alias (through a
  # function returning the module's name, `SchedulingLive`'s
  # `journey_module/0`).
  defp shipped_facts,
    do: %{meeting_type: MeetingType, slot: Slot, answers: Answers, attendee: Attendee}

  # Public (and undocumented) so a test can hand it a clashing module.
  @doc false
  @spec merge_facts!(%{atom() => module()}, [module()]) :: %{atom() => module()}
  def merge_facts!(shipped, extras) do
    Enum.reduce(extras, shipped, fn module, acc ->
      key = module.key()

      if Map.has_key?(acc, key) do
        raise ArgumentError,
              "config :tymeslot, :extra_booking_facts entry #{inspect(module)} has the key " <>
                "#{inspect(key)}, which #{inspect(acc[key])} already has"
      end

      Map.put(acc, key, module)
    end)
  end

  @doc "The fact module for `key`; raises `KeyError` for a key `facts/0` lacks."
  @spec fact!(atom()) :: module()
  def fact!(key), do: Map.fetch!(facts(), key)

  @doc "The journey's moment named `key`, or nil for an outcome or an unknown key."
  @spec moment(t(), atom()) :: Moment.t() | nil
  def moment(journey, key), do: Enum.find(journey.moments, &(&1.key == key))

  @doc "The fact modules `moment` collects that this booking needs, in its order."
  @spec required_facts(Moment.t(), map()) :: [module()]
  def required_facts(moment, assigns) do
    moment.collects
    |> Enum.map(&fact!/1)
    |> Enum.filter(& &1.required?(assigns))
  end

  @doc """
  The options of the classic journey for a `steps:` map: `Navigators.Paged`
  over `overview` (the meeting type), `schedule` (the slot), `questions` (the
  answers, shown only when the meeting type has questions) and `booking` (the
  attendee), ending on the theme's confirmation or the shared payment wait.
  """
  @spec classic(%{atom() => module()}) :: keyword()
  def classic(steps) do
    [
      navigator: Paged,
      moments: [
        {:overview, collects: [:meeting_type], component: steps.overview},
        {:schedule, collects: [:slot], component: steps.schedule},
        {:questions, collects: [:answers], component: steps.questions},
        {:booking, collects: [:attendee], component: steps.booking}
      ],
      outcomes: %{confirmation: steps.confirmation, awaiting_payment: :shared}
    ]
  end

  @doc """
  The journey `opts` describe (`navigator:`, `moments:` as `{key, opts}`
  entries, `outcomes:`), unchecked; `build!/2` is the checked form. The
  payment wait defaults to the shared one.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:navigator, :moments, :outcomes])

    %__MODULE__{
      navigator: Keyword.fetch!(opts, :navigator),
      moments: Enum.map(Keyword.fetch!(opts, :moments), &Moment.new/1),
      outcomes:
        Map.merge(
          %{confirmation: nil, awaiting_payment: :shared},
          Map.new(Keyword.fetch!(opts, :outcomes))
        )
    }
  end

  @doc """
  The journey `opts` describe, checked while a theme compiles. Raises a
  `CompileError` at `caller` naming every problem: an unknown fact; a fact
  collected before one it needs (its `requires/1` given `%{}`, and the answers
  before the attendee when both are collected); a fact collected twice; the
  meeting type, slot or attendee collected by no moment; a moment or outcome
  component that is not a loaded LiveComponent; a default for a fact the
  moment does not collect, or with a strategy its fact does not take; a
  navigator that is not one; a moment key used twice or named like an
  outcome; an unknown outcome; a malformed entry.
  """
  @spec build!(keyword(), Macro.Env.t()) :: t()
  def build!(opts, caller) do
    journey = new_or_compile_error!(opts, caller)

    case problems(journey) do
      [] -> journey
      problems -> compile_error!(caller, Enum.join(problems, "; "))
    end
  end

  @doc false
  @spec live_component?(term()) :: boolean()
  def live_component?(module) do
    is_atom(module) and match?({:module, _}, Code.ensure_compiled(module)) and
      function_exported?(module, :__live__, 0) and module.__live__()[:kind] == :component
  end

  # Public, as `live_component?/1` is, so it takes any term: the struct's
  # type says `module()`, but a journey literal can hold anything.
  @doc false
  @spec navigator?(term()) :: boolean()
  def navigator?(module) do
    is_atom(module) and match?({:module, _}, Code.ensure_compiled(module)) and
      Enum.all?(@navigator_callbacks, fn {name, arity} ->
        function_exported?(module, name, arity)
      end)
  end

  defp new_or_compile_error!(opts, caller) do
    new(opts)
  rescue
    error in [ArgumentError, KeyError, FunctionClauseError, Protocol.UndefinedError] ->
      compile_error!(caller, "the journey is malformed: " <> Exception.message(error))
  end

  @spec compile_error!(Macro.Env.t(), String.t()) :: no_return()
  defp compile_error!(caller, problem) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "use SchedulingLive got a journey it cannot run: " <> problem
  end

  defp problems(journey) do
    facts = facts()
    collected = collected(journey.moments)

    Enum.concat([
      navigator_problems(journey.navigator),
      moment_key_problems(journey.moments),
      unknown_fact_problems(collected, facts),
      twice_problems(collected),
      uncollected_problems(collected),
      order_problems(collected, facts),
      component_problems(journey),
      default_problems(journey.moments, facts)
    ])
  end

  # Every fact a moment collects, with the moment and its place in the
  # journey: `{key, moment_key, {moment_index, index_in_moment}}`.
  defp collected(moments) do
    for {moment, moment_index} <- Enum.with_index(moments),
        {key, index} <- Enum.with_index(moment.collects),
        do: {key, moment.key, {moment_index, index}}
  end

  defp navigator_problems(navigator) do
    if navigator?(navigator) do
      []
    else
      ["navigator #{inspect(navigator)} is not a loaded module implementing Journey.Navigator"]
    end
  end

  defp moment_key_problems(moments) do
    keys = Enum.map(moments, & &1.key)

    Enum.map(duplicates(keys), &"moment key #{inspect(&1)} is used twice") ++
      for(key <- keys, key in @outcome_keys, do: "moment #{inspect(key)} has an outcome's name")
  end

  defp unknown_fact_problems(collected, facts) do
    known = facts |> Map.keys() |> Enum.sort()

    for {key, moment, _place} <- collected,
        not Map.has_key?(facts, key),
        do:
          "moment #{inspect(moment)} collects #{inspect(key)}, which is no known fact " <>
            "(the facts are #{inspect(known)})"
  end

  defp twice_problems(collected) do
    collected
    |> Enum.map(&elem(&1, 0))
    |> duplicates()
    |> Enum.map(&"fact #{inspect(&1)} is collected twice")
  end

  defp uncollected_problems(collected) do
    keys = Enum.map(collected, &elem(&1, 0))

    for key <- @always_collected,
        key not in keys,
        do: "no moment collects #{inspect(key)}, which every booking needs"
  end

  defp order_problems(collected, facts) do
    places = Map.new(collected, fn {key, _moment, place} -> {key, place} end)

    for {key, moment, place} <- collected,
        Map.has_key?(facts, key),
        needed <- static_requires(key, facts, places),
        not before?(places[needed], place),
        do:
          "moment #{inspect(moment)} collects #{inspect(key)}, which needs " <>
            "#{inspect(needed)} collected before it"
  end

  # The answers come before the attendee whenever both are collected: the
  # attendee needs them when the meeting type has questions, which only a
  # booking can say.
  defp static_requires(:attendee, facts, places) when is_map_key(places, :answers),
    do: Enum.uniq(facts[:attendee].requires(%{}) ++ [:answers])

  defp static_requires(key, facts, _places), do: facts[key].requires(%{})

  defp before?(nil, _place), do: false
  defp before?(needed_place, place), do: needed_place < place

  defp component_problems(journey) do
    moments =
      for moment <- journey.moments,
          not live_component?(moment.component),
          do: component_problem("moment #{inspect(moment.key)}", moment.component)

    outcomes = Enum.flat_map(journey.outcomes, &outcome_problems/1)

    moments ++ outcomes
  end

  defp outcome_problems({key, _component}) when key not in @outcome_keys,
    do: ["outcomes are #{inspect(@outcome_keys)}, not #{inspect(key)}"]

  defp outcome_problems({:awaiting_payment, :shared}), do: []

  defp outcome_problems({key, component}) do
    if live_component?(component),
      do: [],
      else: [component_problem("outcome #{inspect(key)}", component)]
  end

  defp component_problem(what, component),
    do:
      "#{what} needs a LiveComponent, got #{inspect(component)}, which is not a loaded LiveComponent"

  defp default_problems(moments, facts) do
    Enum.flat_map(moments, fn moment ->
      Enum.flat_map(moment.defaults, fn {key, strategy} ->
        default_problems(moment, key, strategy, facts)
      end)
    end)
  end

  defp default_problems(moment, key, strategy, facts) do
    cond do
      key not in moment.collects ->
        ["moment #{inspect(moment.key)} defaults #{inspect(key)}, which it does not collect"]

      # An unknown fact is reported once, by `unknown_fact_problems/2`.
      not Map.has_key?(facts, key) ->
        []

      strategy in facts[key].default_strategies() ->
        []

      true ->
        [
          "moment #{inspect(moment.key)} defaults #{inspect(key)} with #{inspect(strategy)}, " <>
            "which #{inspect(facts[key])} does not take (it takes " <>
            "#{inspect(facts[key].default_strategies())})"
        ]
    end
  end

  defp duplicates(list), do: Enum.uniq(list -- Enum.uniq(list))
end
