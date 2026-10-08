defmodule TymeslotWeb.Themes.Shared.Journey.Progress do
  @moduledoc """
  How far a booking has come through a journey, read from the socket's
  assigns: which moments it has reached, in journey order, and in what state.

    * A moment declared with `collects: []` has nothing to collect and is
      `:open` whenever the booking reaches it (a masthead, a prompt).
    * A moment none of whose collected facts this booking requires
      (`required?/1`) is passed over, as `Navigators.Paged` passes it over.
    * Otherwise a moment is `:done` when every fact it collects that the
      booking requires is `known?/1`, and the first one that is not is
      `:current`; nothing after it is reached yet.

  `Navigators.Continuous` and `Navigators.Transcript` show exactly the
  moments `reached/3` returns. Shared code that used to compare
  `:current_state` with a classic step name asks `collecting_now?/2` or
  `at_or_before?/2` instead, which answer the same for the classic journey.

  Every function takes the fact registry as its last argument, default
  `Journey.facts/0`.
  """

  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Moment

  @type state :: :current | :done | :open
  @type facts :: %{atom() => module()}

  @doc "The facts `moment` collects that this booking requires, in declaration order."
  @spec required(Moment.t(), map(), facts()) :: [atom()]
  def required(%Moment{collects: collects}, assigns, facts \\ Journey.facts()),
    do: Enum.filter(collects, &Map.fetch!(facts, &1).required?(assigns))

  @doc """
  The moments the booking has reached, in journey order, each with its state:
  every moment before the current one that it does not pass over, then the
  current one. With every required fact known there is no current moment and
  every reached moment is `:done` or `:open`.
  """
  @spec reached(Journey.t(), map(), facts()) :: [{Moment.t(), state()}]
  def reached(%Journey{moments: moments}, assigns, facts \\ Journey.facts()) do
    moments
    |> Enum.reduce_while([], fn moment, acc ->
      case state(moment, assigns, facts) do
        :pass -> {:cont, acc}
        :current -> {:halt, [{moment, :current} | acc]}
        state -> {:cont, [{moment, state} | acc]}
      end
    end)
    |> Enum.reverse()
  end

  @doc "The current moment, or nil when every required fact is known."
  @spec current(Journey.t(), map(), facts()) :: Moment.t() | nil
  def current(journey, assigns, facts \\ Journey.facts()) do
    Enum.find_value(reached(journey, assigns, facts), fn
      {moment, :current} -> moment
      {_moment, _state} -> nil
    end)
  end

  @doc "The key of the first moment collecting `fact`, or nil when none does."
  @spec moment_for(Journey.t(), atom()) :: atom() | nil
  def moment_for(%Journey{moments: moments}, fact) do
    Enum.find_value(moments, fn %Moment{key: key, collects: collects} ->
      if fact in collects, do: key
    end)
  end

  @doc """
  `fact` and every fact that depends on it for this booking: those whose
  `requires/1` names it, and theirs, transitively. Forgetting a fact forgets
  these with it.
  """
  @spec dependents(atom(), map(), facts()) :: [atom()]
  def dependents(fact, assigns, facts \\ Journey.facts()),
    do: collect_dependents([fact], [], assigns, facts)

  @doc """
  Whether the moment on screen (`:current_state`) collects `fact`. False on an
  outcome and on a page with no journey.
  """
  @spec collecting_now?(map(), atom()) :: boolean()
  def collecting_now?(%{journey: %Journey{moments: moments}} = assigns, fact) do
    case Enum.find(moments, &(&1.key == assigns[:current_state])) do
      %Moment{collects: collects} -> fact in collects
      nil -> false
    end
  end

  def collecting_now?(_assigns, _fact), do: false

  @doc """
  Whether the moment on screen comes no later than the first moment collecting
  `fact`: the booking has not moved past that fact's moment. True before any
  moment is on screen (`:current_state` nil), false on an outcome. For the
  classic journey and `:slot` that is the overview and the schedule step.
  """
  @spec at_or_before?(map(), atom()) :: boolean()
  def at_or_before?(%{journey: %Journey{moments: moments}} = assigns, fact) do
    case assigns[:current_state] do
      nil ->
        true

      key ->
        current = Enum.find_index(moments, &(&1.key == key))
        target = Enum.find_index(moments, &(fact in &1.collects))
        is_integer(current) and is_integer(target) and current <= target
    end
  end

  def at_or_before?(assigns, _fact), do: is_nil(assigns[:current_state])

  defp state(%Moment{collects: []}, _assigns, _facts), do: :open

  defp state(moment, assigns, facts) do
    case required(moment, assigns, facts) do
      [] ->
        :pass

      keys ->
        if Enum.all?(keys, &Map.fetch!(facts, &1).known?(assigns)), do: :done, else: :current
    end
  end

  defp collect_dependents([], seen, _assigns, _facts), do: Enum.reverse(seen)

  defp collect_dependents([fact | rest], seen, assigns, facts) do
    if fact in seen do
      collect_dependents(rest, seen, assigns, facts)
    else
      direct = for {other, module} <- facts, fact in module.requires(assigns), do: other
      collect_dependents(rest ++ direct, [fact | seen], assigns, facts)
    end
  end
end
