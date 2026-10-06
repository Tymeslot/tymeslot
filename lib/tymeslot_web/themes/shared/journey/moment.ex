defmodule TymeslotWeb.Themes.Shared.Journey.Moment do
  @moduledoc """
  One moment of a journey: a LiveComponent the theme writes, collecting zero
  or more facts (`collects:`, keys of `Journey.facts/0`, in the order the
  moment asks them) and settling some of them without asking (`defaults:`,
  fact key to a `Fact.default/2` strategy; checked now, and applied once
  the runtime opens moments). A journey writes it as
  `{key, collects: [...], component: Module, defaults: [...]}`.
  """

  @enforce_keys [:key, :collects, :component]
  defstruct [:key, :collects, :component, defaults: []]

  @type t :: %__MODULE__{
          key: atom(),
          collects: [atom()],
          component: module(),
          defaults: keyword()
        }

  @doc """
  The moment a journey's `{key, opts}` entry describes. Raises
  `ArgumentError` or `KeyError` on a malformed entry; `Journey.build!/2`
  turns either into a `CompileError`.
  """
  @spec new({atom(), keyword()}) :: t()
  def new({key, opts}) when is_atom(key) and is_list(opts) do
    opts = Keyword.validate!(opts, [:collects, :component, defaults: []])
    collects = Keyword.fetch!(opts, :collects)
    defaults = Keyword.fetch!(opts, :defaults)

    unless is_list(collects) and Enum.all?(collects, &is_atom/1),
      do: raise(ArgumentError, "moment #{inspect(key)}: collects: must be a list of fact keys")

    unless Keyword.keyword?(defaults),
      do: raise(ArgumentError, "moment #{inspect(key)}: defaults: must be a keyword list")

    %__MODULE__{
      key: key,
      collects: collects,
      component: Keyword.fetch!(opts, :component),
      defaults: defaults
    }
  end

  def new(other) do
    raise ArgumentError,
          "a moment is {key, collects: [...], component: Module}, got: #{inspect(other)}"
  end
end
