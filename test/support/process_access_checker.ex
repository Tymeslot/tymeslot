defmodule Tymeslot.Test.ProcessAccessChecker do
  @moduledoc """
  A feature access checker whose answer the test sets with `answer/1`, for
  exercising each outcome of `Tymeslot.Features.check_access/2` in turn.

  The answer is kept in the calling process, so it reaches code run in that
  process (`perform_job/2`, `Oban.drain_queue/1`) and nothing else.
  """

  @key {__MODULE__, :answer}

  @doc "Makes every check in this process answer `answer`."
  @spec answer(term()) :: :ok
  def answer(answer) do
    Process.put(@key, answer)
    :ok
  end

  @spec check_access(integer(), atom()) :: term()
  def check_access(_user_id, _feature), do: Process.get(@key, :ok)
end
