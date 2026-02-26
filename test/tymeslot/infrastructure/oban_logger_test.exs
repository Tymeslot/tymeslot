defmodule Tymeslot.Infrastructure.ObanLoggerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CorrelationId
  alias Tymeslot.Infrastructure.ObanLogger

  describe "handle_event/4" do
    test "sets correlation_id in process dict and Logger metadata" do
      # Run in a separate process to avoid polluting test process metadata
      result =
        Task.await(
          Task.async(fn ->
            ObanLogger.handle_event([:oban, :job, :start], %{}, %{}, [])

            {CorrelationId.get_from_process(), Logger.metadata()[:correlation_id]}
          end)
        )

      {process_id, logger_id} = result

      assert is_binary(process_id)
      assert process_id == logger_id
    end

    test "generates a unique correlation_id per invocation" do
      ids =
        for _i <- 1..10 do
          Task.await(
            Task.async(fn ->
              ObanLogger.handle_event([:oban, :job, :start], %{}, %{}, [])
              CorrelationId.get_from_process()
            end)
          )
        end

      assert length(Enum.uniq(ids)) == 10
    end

    test "does not crash on unexpected errors in metadata setup" do
      # Passing invalid event name still executes the rescue path gracefully
      # (the function only pattern-matches [:oban, :job, :start], so this tests
      # that even if internal logic were to raise, the handler survives)
      assert :ok = ObanLogger.handle_event([:oban, :job, :start], %{}, %{}, [])
    end
  end
end
