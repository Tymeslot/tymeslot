defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Engine do
  @moduledoc """
  Pure state machine for the booker-facing custom questions wizard step.

  Holds the ordered snapshot of definitions, the booker's in-progress
  answers, per-question errors, and the current sub-page index. Has no
  knowledge of LiveView — themes wrap the state and render one
  definition at a time.

  The `touched` MapSet tracks which question ids the booker has already
  answered at least once. It's reserved for the theme integration to gate
  inline error rendering ("show errors only on touched fields"). The
  engine itself does not enforce this rule.
  """

  alias Tymeslot.CustomFields

  @type t :: %__MODULE__{
          definitions: [map()],
          current_index: non_neg_integer(),
          answers: %{String.t() => any()},
          errors: %{String.t() => String.t()},
          touched: term()
        }

  defstruct definitions: [],
            current_index: 0,
            answers: %{},
            errors: %{},
            touched: MapSet.new()

  @spec init([map()]) :: t()
  def init(definitions) when is_list(definitions) do
    %__MODULE__{definitions: Enum.sort_by(definitions, &position/1)}
  end

  @doc """
  Seeds answers the booker has not given in this session — the ones a
  reschedule carries over from the booking being moved.

  Deliberately not `answer/3`: these are answers to be *shown*, not answers
  the booker has just made, so they leave `touched` alone. The theme gates
  inline errors on that set, and marking a carried-over answer as touched
  would put an error under a question the booker has not looked at yet.

  Answers already in the state win, so re-entering the step cannot overwrite
  an edit with the value it replaced, and ids the definitions do not carry
  are ignored.
  """
  @spec prefill(t(), %{String.t() => any()}) :: t()
  def prefill(%__MODULE__{} = s, answers) when is_map(answers) do
    known = MapSet.new(s.definitions, & &1["id"])
    carried = Map.filter(answers, fn {id, _value} -> MapSet.member?(known, id) end)

    %{s | answers: Map.merge(carried, s.answers)}
  end

  @spec skipped?(t()) :: boolean()
  def skipped?(%__MODULE__{definitions: []}), do: true
  def skipped?(%__MODULE__{}), do: false

  @spec total(t()) :: non_neg_integer()
  def total(%__MODULE__{definitions: defs}), do: length(defs)

  @spec current_definition(t()) :: map() | nil
  def current_definition(%__MODULE__{definitions: defs, current_index: i}), do: Enum.at(defs, i)

  @spec answer(t(), String.t(), any()) :: t()
  def answer(%__MODULE__{} = s, id, value) do
    %{
      s
      | answers: Map.put(s.answers, id, value),
        touched: MapSet.put(s.touched, id),
        errors: Map.delete(s.errors, id)
    }
  end

  @spec next(t()) :: {:ok, t()} | {:error, t()}
  def next(%__MODULE__{definitions: []} = s), do: {:error, s}

  def next(%__MODULE__{} = s) do
    case validate_current(s) do
      {:ok, normalised} ->
        current_id = current_definition(s)["id"]

        s = %{
          s
          | answers: Map.put(s.answers, current_id, normalised),
            errors: Map.delete(s.errors, current_id)
        }

        {:ok, %{s | current_index: min(s.current_index + 1, length(s.definitions) - 1)}}

      {:error, msg} ->
        current_id = current_definition(s)["id"]
        {:error, %{s | errors: Map.put(s.errors, current_id, msg)}}
    end
  end

  @spec prev(t()) :: t()
  def prev(%__MODULE__{current_index: 0} = s), do: s
  def prev(%__MODULE__{} = s), do: %{s | current_index: s.current_index - 1}

  @spec validate_all(t()) :: {:ok, map()} | {:error, %{String.t() => String.t()}}
  def validate_all(%__MODULE__{definitions: defs, answers: ans}),
    do: CustomFields.validate_answers(defs, ans)

  defp validate_current(%__MODULE__{} = s) do
    case current_definition(s) do
      nil -> {:error, "No question to validate"}
      d -> CustomFields.validate_answer(Map.get(s.answers, d["id"]), d)
    end
  end

  defp position(%{"position" => p}), do: p || 0
  defp position(%{position: p}), do: p || 0
  defp position(_field), do: 0
end
