defmodule Tymeslot.Precommit.Tee do
  @moduledoc """
  A `Collectable` that writes each chunk of a command's output to standard
  output as it arrives and keeps a copy, for `System.cmd/3`'s `:into` option.

  `Tymeslot.Precommit.Runner` streams its compile steps live, and also has to
  read what they printed afterwards: an exit status of zero does not mean the
  step printed no warnings.
  """

  defstruct chunks: []

  @type t :: %__MODULE__{chunks: [binary()]}

  @doc "Everything collected so far, as one binary."
  @spec output(t()) :: binary()
  def output(%__MODULE__{chunks: chunks}), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defimpl Collectable do
    alias Tymeslot.Precommit.Tee

    @spec into(Tee.t()) :: {Tee.t(), (Tee.t(), Collectable.command() -> Tee.t() | :ok)}
    def into(%Tee{} = tee) do
      collector = fn
        %Tee{chunks: chunks} = acc, {:cont, chunk} ->
          IO.write(chunk)
          %{acc | chunks: [chunk | chunks]}

        acc, :done ->
          acc

        _acc, :halt ->
          :ok
      end

      {tee, collector}
    end
  end
end
