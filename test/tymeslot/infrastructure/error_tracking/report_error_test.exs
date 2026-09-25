defmodule Tymeslot.Infrastructure.ErrorTracking.ReportErrorTest do
  # async: false: ErrorTracker's `enabled` switch, the crash reporter's
  # `:logger` handler and the telemetry handlers are all global.
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  import Ecto.Query
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.CrashReporter
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.ErrorTracking.HandledError
  alias Tymeslot.Test.LogCapture

  @telemetry_handler "report-error-test-occurrences"

  @doc false
  @spec forward_occurrence([atom()], map(), map(), pid()) :: :ok
  def forward_occurrence(_event, _measurements, %{occurrence: occurrence}, test_pid) do
    send(test_pid, {:occurrence_recorded, occurrence})
    :ok
  end

  setup do
    with_config(:error_tracker, enabled: true)

    :ok =
      :telemetry.attach(
        @telemetry_handler,
        [:error_tracker, :occurrence, :new],
        &__MODULE__.forward_occurrence/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(@telemetry_handler) end)
    :ok
  end

  defp errors, do: Repo.all(from(e in Error, preload: :occurrences))

  defp raise_and_capture(message) do
    raise message
  rescue
    exception -> {exception, __STACKTRACE__}
  end

  # One call site for the plain reasons, so two calls share a source frame as
  # two calls from one line of production code do. Not a tail call, so this
  # function's own frame is on the stack.
  defp report_reason(reason, context) do
    :ok = ErrorTracking.report_error(reason, nil, context)
    :ok
  end

  describe "report_error/3 with an exception" do
    test "stores the exception with its context and logs it at :error" do
      LogCapture.attach()
      {exception, stacktrace} = raise_and_capture("handler blew up")

      assert ErrorTracking.report_error(exception, stacktrace, %{meeting_id: 42}) == :ok

      assert [%Error{kind: "Elixir.RuntimeError", reason: "handler blew up"} = error] = errors()
      assert [%{context: %{"meeting_id" => 42}}] = error.occurrences

      event = LogCapture.await_log("Handled an unexpected error")
      assert event.level == :error
      assert event.meta.meeting_id == 42
      assert event.meta.error_kind == "RuntimeError"
      assert event.meta.error_message == "handler blew up"
    end
  end

  describe "report_error/3 with a plain reason" do
    for {label, reason_fun, message} <- [
          {"an atom", quote(do: fn _id -> :timeout end), ":timeout"},
          {"a tuple", quote(do: fn id -> {:http_error, 500, "request #{id}"} end),
           ~s({:http_error, _, "..."})},
          {"a map", quote(do: fn id -> %{id: id} end), "%{...}"}
        ] do
      test "groups #{label} reported twice with different ids into one error" do
        reason = unquote(reason_fun)

        for id <- [1, 2], do: report_reason(reason.(id), %{meeting_id: id})

        kind = Atom.to_string(HandledError)
        assert [%Error{kind: ^kind, reason: unquote(message)} = error] = errors()

        contexts = error.occurrences |> Enum.map(& &1.context) |> Enum.sort_by(& &1["meeting_id"])
        assert [%{"meeting_id" => 1}, %{"meeting_id" => 2}] = contexts
        assert Enum.all?(error.occurrences, &(&1.reason == unquote(message)))
        assert Enum.at(contexts, 1)["error.reason"] == HandledError.bounded_inspect(reason.(2))
      end
    end

    test "takes the caller of report_error/3 as the error's source" do
      :ok = report_reason(:timeout, %{})

      assert [%Error{source_function: source}] = errors()
      assert source == "#{inspect(__MODULE__)}.report_reason/2"
    end

    test "keeps the logged reason bounded" do
      LogCapture.attach()

      :ok = report_reason({:error, String.duplicate("x", 10_000)}, %{})

      event = LogCapture.await_log("Handled an unexpected error")
      assert event.meta.error_message == ~s({:error, "..."})
      assert String.length(event.meta.reason) < 300
    end
  end

  describe "report_error/3 inside a transaction" do
    test "still stores the error when the transaction rolls back" do
      CaptureLog.capture_log(fn ->
        {:error, :rolled_back} =
          Repo.transaction(fn ->
            :ok = report_reason(:timeout, %{meeting_id: 7})
            Repo.rollback(:rolled_back)
          end)
      end)

      assert_receive {:occurrence_recorded, _occurrence}, 2_000
      assert [%Error{} = error] = errors()
      assert [%{context: %{"meeting_id" => 7}}] = error.occurrences
    end
  end

  describe "report_error/3 in a process that later crashes" do
    setup do
      :ok = CrashReporter.attach()
      on_exit(fn -> CrashReporter.detach() end)
      :ok
    end

    # Without the direct-report mark the crash reporter would take the later
    # crash (same kind, same message) for the one already recorded, and skip it.
    test "the later crash is recorded too" do
      CaptureLog.capture_log(fn ->
        {:ok, _pid} =
          Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
            {exception, stacktrace} = raise_and_capture("same failure")
            :ok = ErrorTracking.report_error(exception, stacktrace, %{})
            raise "same failure"
          end)

        assert_receive {:occurrence_recorded, _handled}, 2_000
        assert_receive {:occurrence_recorded, _crash}, 2_000
      end)

      assert errors() |> Enum.flat_map(& &1.occurrences) |> length() == 2
    end
  end

  describe "report_error/3 when recording fails" do
    test "returns :ok and logs the failure instead of raising" do
      with_config(:error_tracker, repo: __MODULE__.NotARepo)
      LogCapture.attach()

      assert ErrorTracking.report_error(:timeout, nil, %{meeting_id: 1}) == :ok

      event = LogCapture.await_log("Failed to record a handled error")
      assert event.meta.error == "UndefinedFunctionError"
    end
  end
end
