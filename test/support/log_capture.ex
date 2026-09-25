defmodule Tymeslot.Test.LogCapture do
  @moduledoc """
  An Erlang `:logger` handler that forwards whole log events to a test process,
  so tests can assert on log **metadata**.

  `ExUnit.CaptureLog.capture_log/1` returns what the console formatter printed,
  and that formatter renders the message plus a fixed metadata whitelist only.
  Every other key the code under test attached (`event_type`, `path`,
  `email_masked`, the structured keys JSON logging ships in production) is
  dropped before the string exists, so a `capture_log` assertion can neither see
  them nor prove they are absent. This handler receives the raw `:logger` event
  instead, metadata intact, and sends it on to every attached test process as
  `{:captured_log, event}`.

      alias Tymeslot.Test.LogCapture

      setup do
        LogCapture.attach()
        :ok
      end

      test "logs the redacted path" do
        Metrics.handle_http_event(...)

        assert_receive {:captured_log, %{level: :error, meta: meta}}
        assert meta.path == "/calendar/v3/calendars/:id/events"
      end

  Use `with_capture/2` where capturing must stop again before the test body
  ends (for instance because something else has to be restored around it).

  ## One handler for the whole suite

  `install/0` adds the handler once, from `test_helper.exs`, and nothing removes
  it. `attach/1` only registers the calling process in an ETS table the handler
  reads, and detaching deletes that row; neither touches `:logger`'s handler
  list.

  That is deliberate: adding and removing handlers while other processes do the
  same is unsafe. `:logger`'s server computes the new handler list for a
  `remove_handler` when the request arrives but writes it back only after the
  queue of earlier handler operations has drained, so a stale list can undo a
  concurrent change. When the undone change is `ExUnit.CaptureServer` removing
  its own handler, the next `capture_log` adds that handler a second time, and
  every captured line is written twice for the rest of the run. Attaching a
  handler per test from async modules triggered exactly that. The race is in
  OTP itself (`logger_server`, unchanged as of OTP 29.1), so a test must never
  add or remove a `:logger` handler while other tests run.

  ## Isolation

  A `:logger` handler is global: it sees events from every process, so a test
  that attaches also receives whatever concurrently running async tests log.
  Two consequences, both of which are the caller's responsibility:

  - A module that lowers the primary Logger level (`:logger_level`) or asserts
    on the *absence* of a log (`refute_receive {:captured_log, _}`) must be
    `async: false`; neither is safe to run alongside other tests.
  - A module that only asserts on the presence of its own event may stay async,
    but must match tightly enough not to trip over a foreign event. Match on a
    distinctive metadata key, or pull events until the expected one arrives.
  """

  alias ExUnit.Assertions
  alias ExUnit.Callbacks

  # Set by :logger itself on every event, never by the code under test.
  @logger_injected_keys [
    :application,
    :domain,
    :erl_level,
    :error_logger,
    :file,
    :function,
    :gl,
    :line,
    :mfa,
    :module,
    :pid,
    :report_cb,
    :time
  ]

  @handler_id :tymeslot_log_capture

  @type opt ::
          {:level, :logger.level() | :all | :none}
          | {:logger_level, Logger.level()}

  @doc """
  Adds the suite-wide capture handler and creates the table `attach/1` registers
  in. Call once from `test_helper.exs`, before `ExUnit.start/1`; the calling
  process owns the table, so it must live as long as the suite does.
  """
  @spec install() :: :ok
  def install do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    :ok = :logger.add_handler(@handler_id, __MODULE__, %{level: :all})
  end

  @doc """
  Forwards log events to the calling test process until the test exits.

  Options:

  - `:level` - the least severe level forwarded. Defaults to `:all`; the
    primary Logger level still applies on top of it.
  - `:logger_level` - lower the *primary* Logger level for the duration, and
    restore it afterwards. Needed for events emitted below the level
    `config/test.exs` pins. Global: only for `async: false` modules.
  """
  @spec attach([opt()]) :: :ok
  def attach(opts \\ []) do
    opts |> start_capture() |> Callbacks.on_exit()
    :ok
  end

  @doc """
  Runs `fun` while forwarding log events to the calling process, then stops
  forwarding and restores any `:logger_level` override. Returns `fun`'s result.

  Takes the same options as `attach/1`.
  """
  @spec with_capture([opt()], (-> result)) :: result when result: var
  def with_capture(opts \\ [], fun) do
    restore = start_capture(opts)

    try do
      fun.()
    after
      restore.()
    end
  end

  @doc """
  Pulls captured events until one whose message contains `text` arrives, and
  returns it; fails the test if none does within `timeout`.

  Necessary whenever other tests may log concurrently: the handler is global, so
  the first event to arrive is not necessarily this test's.
  """
  @spec await_log(String.t(), timeout()) :: :logger.log_event() | no_return()
  def await_log(text, timeout \\ 1_000) do
    receive do
      {:captured_log, %{msg: msg} = event} ->
        if message_text(msg) =~ text, do: event, else: await_log(text, timeout)
    after
      timeout -> Assertions.flunk("no captured log event whose message contains #{inspect(text)}")
    end
  end

  @doc """
  Returns every captured event currently waiting in the test process's mailbox,
  oldest first. Handler callbacks run in the logging process, so anything logged
  synchronously by the code under test has already arrived by the time it
  returns.
  """
  @spec drain() :: [:logger.log_event()]
  def drain, do: Enum.reverse(drain([]))

  @doc """
  Renders one event's message and caller-supplied metadata as a single string,
  for `refute … =~ "secret"` assertions that must cover the whole log record.

  The keys `:logger` injects itself (timestamps, pid, file/line, …) are dropped,
  so an assertion cannot accidentally match on them.
  """
  @spec dump(:logger.log_event()) :: String.t()
  def dump(%{msg: msg} = event) do
    inspect(%{message: message_text(msg), metadata: user_metadata(event)},
      limit: :infinity,
      printable_limit: :infinity
    )
  end

  @doc """
  The metadata the caller attached, with the keys `:logger` adds itself removed.
  """
  @spec user_metadata(:logger.log_event()) :: map()
  def user_metadata(%{meta: meta}), do: Map.drop(meta, @logger_injected_keys)

  @doc """
  Renders a `:logger` event's `:msg` as a binary, for tests that need to match
  on the message text as well as the metadata.
  """
  @spec message_text(term()) :: String.t()
  def message_text({:string, chardata}), do: IO.chardata_to_string(chardata)
  def message_text({:report, report}), do: inspect(report)

  def message_text({format, args}) when is_list(args),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  def message_text(other), do: inspect(other)

  @doc false
  @spec log(:logger.log_event(), :logger.handler_config()) :: :ok
  def log(%{level: level} = event, _config) do
    for {_ref, pid, min_level} <- :ets.tab2list(__MODULE__), forwards?(level, min_level) do
      send(pid, {:captured_log, event})
    end

    :ok
  end

  defp forwards?(_level, :all), do: true
  defp forwards?(_level, :none), do: false
  defp forwards?(level, min_level), do: :logger.compare_levels(level, min_level) != :lt

  @spec drain([:logger.log_event()]) :: [:logger.log_event()]
  defp drain(acc) do
    receive do
      {:captured_log, event} -> drain([event | acc])
    after
      0 -> acc
    end
  end

  @spec start_capture([opt()]) :: (-> :ok)
  defp start_capture(opts) do
    ref = make_ref()
    original_level = Logger.level()
    logger_level = Keyword.get(opts, :logger_level)

    if logger_level, do: Logger.configure(level: logger_level)

    true = :ets.insert_new(__MODULE__, {ref, self(), Keyword.get(opts, :level, :all)})

    fn ->
      :ets.delete(__MODULE__, ref)
      if logger_level, do: Logger.configure(level: original_level)
      :ok
    end
  end
end
