defmodule Tymeslot.Infrastructure.Logging.LogFormatTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.Logging.LogFormat

  describe "reason/1" do
    test "keeps the value of a sensitive key out of the rendered reason" do
      rendered = LogFormat.reason(%{access_token: "abc"})

      refute rendered =~ "abc"
      assert rendered =~ "access_token"
    end

    test "redacts sensitive keys the string patterns do not know" do
      rendered = LogFormat.reason({:error, %{"client" => %{secret: "s3cret-value"}}})

      refute rendered =~ "s3cret-value"
      assert rendered =~ ":error"
    end

    test "redacts a credential that only appears inside a string" do
      rendered = LogFormat.reason({:http_error, 401, "Authorization: Bearer abc.def.ghi"})

      refute rendered =~ "abc.def.ghi"
      assert rendered =~ "401"
    end

    test "masks an email address quoted in the reason" do
      rendered = LogFormat.reason({:not_found, "alice@example.com"})

      refute rendered =~ "alice@example.com"
      assert rendered =~ "@example.com"
    end

    test "renders an ordinary reason exactly as inspect/1 does" do
      reason = {:error, :timeout, %{status: 503, attempts: [1, 2, 3]}}

      assert LogFormat.reason(reason) == inspect(reason)
    end

    test "bounds a long collection and a long string" do
      long_list = LogFormat.reason(Enum.to_list(1..10_000))
      long_string = LogFormat.reason(String.duplicate("a", 100_000))

      assert long_list =~ "..."
      assert byte_size(long_list) < 1_000
      assert byte_size(long_string) < 10_000
    end

    test "bounds the total size of a wide nested term" do
      wide = Map.new(1..40, fn i -> {i, Enum.to_list(1..40)} end)

      assert byte_size(LogFormat.reason(wide)) <= 4_096 + byte_size("... [TRUNCATED]")
    end

    test "renders exceptions, pids and funs without raising" do
      assert LogFormat.reason(%RuntimeError{message: "boom"}) =~ "boom"
      assert LogFormat.reason(self()) =~ "#PID<"
      assert LogFormat.reason(fn -> :ok end) =~ "#Function<"
      assert LogFormat.reason(["abc" | "def"]) == inspect(["abc" | "def"])
    end
  end

  describe "stacktrace/1" do
    test "renders each frame's arity, never its arguments" do
      # The shape a FunctionClauseError leaves at the top of its stacktrace:
      # the call's arguments in place of its arity.
      stacktrace = [
        {Tymeslot.Sync, :apply_event, [%{password: "pw-leak"}], [file: ~c"lib/sync.ex", line: 3]}
      ]

      rendered = LogFormat.stacktrace(stacktrace)

      assert rendered =~ "Tymeslot.Sync.apply_event/1"
      refute rendered =~ "pw-leak"
    end

    test "passes a frame that already carries its arity through" do
      rendered = LogFormat.stacktrace([{Enum, :map, 2, [file: ~c"lib/enum.ex", line: 1]}])

      assert rendered =~ "Enum.map/2"
      assert rendered =~ "lib/enum.ex:1"
    end
  end
end
