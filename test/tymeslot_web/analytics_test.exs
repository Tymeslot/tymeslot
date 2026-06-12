defmodule TymeslotWeb.AnalyticsTest do
  @moduledoc """
  Unit tests for the client analytics bridge. The critical guarantee is that
  STRICT mode (dev/test) actually RAISES on a PII/undeclared event at the source
  — the rescue around the emit side-effect must NOT swallow validation errors.
  In non-strict mode (prod) the event is dropped and only key NAMES are logged,
  never prop values.
  """
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  import ExUnit.CaptureLog

  alias TymeslotWeb.Analytics

  # A bare socket is enough: push_event/3 only writes to socket.private.live_temp.
  defp socket, do: %Phoenix.LiveView.Socket{}

  # The push_events list is stored newest-first under live_temp; nil when none.
  defp push_events(%Phoenix.LiveView.Socket{} = socket) do
    socket.private.live_temp[:push_events] || []
  end

  describe "strict mode (analytics_strict: true, the dev/test default)" do
    test "raises on an undeclared (PII) prop — the rescue does not swallow it" do
      assert_raise ArgumentError, fn ->
        Analytics.push(socket(), "onboarding_step_completed", %{user_id: 99})
      end
    end

    test "raises on an unknown event" do
      assert_raise ArgumentError, fn ->
        Analytics.push(socket(), "no_such_event", %{})
      end
    end

    test "does not leak the offending prop VALUE when it raises" do
      # The validator interpolates inspect(value) for a non-categorical value.
      # Even so, the raise path must not log the value anywhere.
      log =
        capture_log(fn ->
          assert_raise ArgumentError, fn ->
            Analytics.push(socket(), "onboarding_step_completed", %{step: %{secret: "leak-123"}})
          end
        end)

      refute log =~ "leak-123"
    end

    test "emits and pushes the event for a valid payload" do
      socket = Analytics.push(socket(), "onboarding_step_completed", %{step: "profile"})

      assert [["ts:analytics", payload]] = push_events(socket)
      assert payload == %{name: "onboarding_step_completed", props: %{step: "profile"}}
    end
  end

  describe "non-strict mode (analytics_strict: false, prod)" do
    setup do
      prior = Application.get_env(:tymeslot, :analytics_strict, true)
      Application.put_env(:tymeslot, :analytics_strict, false)
      on_exit(fn -> Application.put_env(:tymeslot, :analytics_strict, prior) end)
    end

    test "drops the event (no push queued) instead of raising" do
      out_socket = Analytics.push(socket(), "onboarding_step_completed", %{user_id: 99})

      assert push_events(out_socket) == []
    end

    test "logs the dropped event but never the prop VALUE" do
      log =
        capture_log(fn ->
          Analytics.push(socket(), "onboarding_step_completed", %{user_id: "secret-value-123"})
        end)

      assert log =~ "analytics event dropped"
      # The offending key names go to keyword metadata (rendered by logger_json
      # in prod); the security guarantee under test is that the prop VALUE is
      # never written to the log.
      refute log =~ "secret-value-123"
    end

    test "still pushes a valid event" do
      socket = Analytics.push(socket(), "onboarding_step_completed", %{step: "profile"})

      assert [["ts:analytics", %{name: "onboarding_step_completed"}]] = push_events(socket)
    end
  end
end
