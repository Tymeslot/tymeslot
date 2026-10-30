defmodule Tymeslot.TestHelpers.Eventually do
  @moduledoc """
  Helper for deterministic polling in tests to replace brittle `Process.sleep` calls.

  This module provides utilities to wait for asynchronous operations to complete
  by repeatedly checking a condition until it becomes true or a timeout occurs.

  ## Why Use This?

  Instead of using fixed sleep times (which are unreliable and slow):

      test "updates state" do
        trigger_update()
        Process.sleep(100)  # ❌ Brittle: might be too short or too long
        assert updated?()
      end

  You can write:

      test "updates state" do
        trigger_update()
        eventually(fn -> assert updated?() end)  # ✅ Polls until true
      end

  ## Common Use Cases

  ### Waiting for LiveView Updates

      test "shows success message after save" do
        view |> element("form") |> render_submit(%{name: "New Name"})

        eventually(fn ->
          assert render(view) =~ "Successfully saved"
        end)
      end

  ### Waiting for Background Jobs

      test "processes Oban job" do
        insert_job()

        eventually(fn ->
          assert Repo.all(Job) == []  # Job was processed and deleted
        end, timeout: 5000)
      end

  ### Waiting for Cache Updates

      test "clears cache after update" do
        update_user(user)

        eventually(fn ->
          refute AvailabilityCache.get(user.id)
        end)
      end

  ### Custom Error Messages

      test "meeting appears in list" do
        create_meeting()

        eventually(
          fn ->
            meetings = list_meetings()
            assert length(meetings) == 1
          end,
          timeout: 2000,
          message: "Expected meeting to appear in list within 2 seconds"
        )
      end

  ## Configuration Options

  - `:timeout` - Maximum time to wait in milliseconds (default: 1000ms)
  - `:interval` - How often to retry in milliseconds (default: 50ms)
  - `:message` - Custom error message when timeout occurs

  ## Important Notes

  - The function will be called repeatedly until it returns a truthy value
  - If it raises an `ExUnit.AssertionError`, it will retry until timeout
  - On timeout, the function is called one final time and any error is propagated
  - The default timeout of 1000ms is suitable for most in-memory operations
  - For external services or Oban jobs, consider longer timeouts (2000-5000ms)
  """

  @doc """
  Repeatedly executes the given function until it returns truthy or times out.

  ## Parameters

  - `func` - A zero-arity function that performs the check/assertion
  - `opts` - Keyword list of options:
    - `:timeout` - Maximum wait time in milliseconds (default: 1000)
    - `:interval` - Polling interval in milliseconds (default: 50)
    - `:message` - Custom error message for timeout failures

  ## Examples

      # Basic usage with defaults (1000ms timeout, 50ms interval)
      eventually(fn -> assert render(view) =~ "loaded" end)

      # Custom timeout for slow operations
      eventually(fn ->
        assert Repo.get(Meeting, id).status == :confirmed
      end, timeout: 5000)

      # Custom interval for very fast operations
      eventually(fn ->
        assert GenServer.call(MyServer, :get_state) == :ready
      end, interval: 10)

      # Custom error message
      eventually(
        fn -> assert page_loaded?(view) end,
        timeout: 3000,
        message: "Expected page to finish loading within 3 seconds"
      )

  ## Returns

  Returns the truthy value from the function on success, or raises an
  `ExUnit.AssertionError` with context about the timeout on failure.
  """
  @spec eventually((-> any()), keyword()) :: any()
  def eventually(func, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 50)
    message = Keyword.get(opts, :message)
    start_time = System.monotonic_time(:millisecond)

    do_eventually(func, timeout, interval, start_time, message)
  end

  defp do_eventually(func, timeout, interval, start_time, message) do
    if result = func.() do
      result
    else
      retry_or_fail(func, timeout, interval, start_time, message, nil)
    end
  rescue
    e in [ExUnit.AssertionError] ->
      retry_or_fail(func, timeout, interval, start_time, message, e)
  end

  defp retry_or_fail(func, timeout, interval, start_time, message, last_error) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - start_time

    if elapsed < timeout do
      Process.sleep(interval)
      do_eventually(func, timeout, interval, start_time, message)
    else
      # Timeout reached - make final attempt and provide helpful error
      try do
        result = func.()

        if result do
          result
        else
          error_message =
            build_timeout_message(message, elapsed, "Condition returned falsy value")

          raise ExUnit.AssertionError, message: error_message
        end
      rescue
        e in [ExUnit.AssertionError] ->
          error_message = build_timeout_message(message, elapsed, last_error || e)
          reraise ExUnit.AssertionError, [message: error_message], __STACKTRACE__
      end
    end
  end

  defp build_timeout_message(nil, elapsed, error) do
    error_text =
      if is_binary(error) do
        error
      else
        Exception.message(error)
      end

    """
    eventually/2 timed out after #{elapsed}ms

    The condition was checked repeatedly but never became true.

    Last error:
    #{error_text}

    Tip: Consider increasing the timeout if the operation legitimately needs more time,
    or check if the condition can ever become true.
    """
  end

  defp build_timeout_message(custom_message, elapsed, _error) do
    """
    eventually/2 timed out after #{elapsed}ms

    #{custom_message}
    """
  end
end
