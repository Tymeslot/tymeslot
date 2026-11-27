defmodule Tymeslot.Precommit.StepFilter do
  @moduledoc """
  Picks a subset of the gate's steps by name, for `--only` and `--skip`.

      $ mix precommit --only credo,dialyzer
      $ mix precommit --skip test,js --affected
      $ mix precommit --only "css tokens"

  Each takes a comma-separated list of step names as the summary prints them,
  and may be repeated; the two cannot be combined. A name the gate does not
  have fails the run instead of being ignored: a mistyped `--skip` would
  otherwise run the very step it meant to leave out. The steps left out are
  listed as not run, so a partial run never reads as a full one.

  The filter applies first, so it composes with `--affected` and the pass
  record: it bounds what may run, and they decide which of those still must.
  Leaving out the compile steps also leaves out their barrier, so the static
  checks then run one after another against whatever build is there.
  """

  alias Tymeslot.Precommit.Runner

  @switches [only: :keep, skip: :keep]

  @doc "The `OptionParser` switches `filter/2` reads."
  @spec switches() :: keyword()
  def switches, do: @switches

  @doc """
  Returns the steps `opts` selects, in gate order, and the others as
  `{name, reason}` pairs for the summary.

  Raises `Mix.Error` for a name `steps` does not contain, or when `--only` and
  `--skip` are both given.
  """
  @spec filter([Runner.step()], keyword()) :: {[Runner.step()], [{String.t(), String.t()}]}
  def filter(steps, opts) do
    case {names(opts, :only), names(opts, :skip)} do
      {[], []} -> {steps, []}
      {only, []} -> split(steps, only, &(&1 in only), "left out by --only")
      {[], skip} -> split(steps, skip, &(&1 not in skip), "left out by --skip")
      _both -> Mix.raise("--only and --skip cannot be combined")
    end
  end

  defp names(opts, key) do
    opts
    |> Keyword.get_values(key)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split(steps, requested, keep?, reason) do
    known = Enum.map(steps, fn {name, _args, _env} -> name end)

    case requested |> Enum.reject(&(&1 in known)) |> Enum.uniq() do
      [] ->
        :ok

      unknown ->
        Mix.raise(
          "no precommit step named #{Enum.map_join(unknown, ", ", &inspect/1)}; " <>
            "this gate's steps are: #{Enum.join(known, ", ")}"
        )
    end

    {kept, left_out} = Enum.split_with(steps, fn {name, _args, _env} -> keep?.(name) end)
    {kept, Enum.map(left_out, fn {name, _args, _env} -> {name, reason} end)}
  end
end
