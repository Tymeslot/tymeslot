defmodule Tymeslot.Test.ReservingDemoProvider do
  @moduledoc """
  Test-only demo provider that reserves one username, `demo-x-1`.

  It answers `demo_username?/1` for that username and hands every other
  callback to `Tymeslot.Demo.NoOp`, so pages keep rendering real data. Wire it
  in for one test with `with_config(:tymeslot, demo_provider: __MODULE__)`, in a
  module that is `async: false`.
  """
  @behaviour Tymeslot.Demo.Behaviour

  alias Tymeslot.Demo.NoOp

  @reserved_username "demo-x-1"

  @doc "The one username this provider reserves."
  @spec reserved_username() :: String.t()
  def reserved_username, do: @reserved_username

  @impl Tymeslot.Demo.Behaviour
  def demo_username?(username), do: username == @reserved_username

  for {name, arity} <- Tymeslot.Demo.Behaviour.behaviour_info(:callbacks),
      name != :demo_username? do
    args = Macro.generate_arguments(arity, __MODULE__)

    @impl Tymeslot.Demo.Behaviour
    def unquote(name)(unquote_splicing(args)), do: NoOp.unquote(name)(unquote_splicing(args))
  end
end
