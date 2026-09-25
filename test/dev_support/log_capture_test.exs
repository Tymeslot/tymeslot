defmodule Tymeslot.Test.LogCaptureTest do
  # async: false - asserts on the node-wide :logger handler list and on the
  # absence of a log, both of which a concurrent test would disturb.
  use ExUnit.Case, async: false

  alias Tymeslot.Test.LogCapture

  require Logger

  @moduletag :dev_support

  describe "attach/1" do
    test "adds no :logger handler, so attaching cannot race ExUnit's capture handler" do
      before = :logger.get_handler_ids()

      LogCapture.attach()
      LogCapture.with_capture(fn -> assert :logger.get_handler_ids() == before end)

      assert :logger.get_handler_ids() == before
    end

    test "forwards an event to the attached process with its metadata intact" do
      LogCapture.attach()

      Logger.warning("log capture forwards this", capture_probe: :forwarded)

      event = LogCapture.await_log("log capture forwards this")
      assert event.meta.capture_probe == :forwarded
    end

    test "forwards each event once" do
      LogCapture.attach()

      Logger.warning("log capture counts this", capture_probe: :counted)
      Logger.flush()

      counted =
        Enum.filter(LogCapture.drain(), fn event -> event.meta[:capture_probe] == :counted end)

      assert length(counted) == 1
    end

    test "withholds events less severe than :level" do
      LogCapture.attach(level: :error)

      Logger.warning("log capture withholds this", capture_probe: :below_level)
      Logger.error("log capture keeps this", capture_probe: :at_level)

      probes = for event <- LogCapture.drain(), do: event.meta[:capture_probe]

      assert :at_level in probes
      refute :below_level in probes
    end
  end

  describe "with_capture/2" do
    test "stops forwarding once the function returns" do
      LogCapture.with_capture(fn -> :ok end)

      Logger.warning("log capture is detached", capture_probe: :after_detach)
      Logger.flush()

      refute_received {:captured_log, %{meta: %{capture_probe: :after_detach}}}
    end
  end
end
