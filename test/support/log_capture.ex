defmodule Tymeslot.Test.LogCapture do
  @moduledoc """
  An Erlang `:logger` handler that forwards whole log events to a test process,
  so tests can assert on log **metadata**.

  `ExUnit.CaptureLog.capture_log/1` returns what the console formatter printed,
  and that formatter renders the message plus a fixed metadata whitelist only.
  Every other key the code under test attached (`event_type`, `path`,
  `email_masked`, the structured keys JSON logging ships in production) is
  dropped before the string exists, so a `capture_log` assertion can neither see
  them nor prove they are absent. This handler is attached instead: it receives
  the raw `:logger` event, metadata intact, and sends it on as
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

  Use `with_capture/2` where the handler must come off again before the test
  body ends (for instance because something else has to be restored around it).

  ## Isolation

  A `:logger` handler is global: it sees events from every process, so a handler
  attached by one test also receives whatever concurrently running async tests
  log. Two consequences, both of which are the caller's responsibility:

  - A module that lowers the primary Logger level (`:logger_level`) or asserts
    on the *absence* of a log (`refute_receive {:captured_log, _}`) must be
    `async: false`; neither is safe to run alongside other tests.
  - A module that only asserts on the presence of its own event may stay async,
    but must match tightly enough not to trip over a foreign event. Match on a
    distinctive metadata key, or pull events until the expected one arrives.

  Each `attach/1` gets its own handler id unless one is passed, so two modules
  can never collide on the id itself.
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

  @type opt ::
          {:id, atom()}
          | {:level, :logger.level() | :all | :none}
          | {:logger_level, Logger.level()}

  @doc """
  Attaches a capture handler that forwards log events to the calling test
  process, and detaches it when the test exits. Returns the handler id.

  Options:

  - `:id` - handler id to use. Defaults to a fresh unique id.
  - `:level` - handler-level threshold. Defaults to `:all`; the primary Logger
    level still applies on top of it.
  - `:logger_level` - lower the *primary* Logger level for the duration, and
    restore it afterwards. Needed for events emitted below the level
    `config/test.exs` pins. Global: only for `async: false` modules.
  """
  @spec attach([opt()]) :: atom()
  def attach(opts \\ []) do
    {id, restore} = start_capture(self(), opts)
    Callbacks.on_exit(restore)
    id
  end

  @doc """
  Runs `fun` with a capture handler attached, then detaches it and restores any
  `:logger_level` override. Returns `fun`'s result.

  Takes the same options as `attach/1`.
  """
  @spec with_capture([opt()], (-> result)) :: result when result: var
  def with_capture(opts \\ [], fun) do
    {_id, restore} = start_capture(self(), opts)

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
  def log(event, %{config: %{pid: pid}}) do
    send(pid, {:captured_log, event})
    :ok
  end

  @spec drain([:logger.log_event()]) :: [:logger.log_event()]
  defp drain(acc) do
    receive do
      {:captured_log, event} -> drain([event | acc])
    after
      0 -> acc
    end
  end

  @spec start_capture(pid(), [opt()]) :: {atom(), (-> :ok)}
  defp start_capture(pid, opts) do
    id = Keyword.get_lazy(opts, :id, &unique_id/0)
    original_level = Logger.level()
    logger_level = Keyword.get(opts, :logger_level)

    if logger_level, do: Logger.configure(level: logger_level)

    :ok =
      :logger.add_handler(id, __MODULE__, %{
        level: Keyword.get(opts, :level, :all),
        config: %{pid: pid}
      })

    restore = fn ->
      :logger.remove_handler(id)
      if logger_level, do: Logger.configure(level: original_level)
      :ok
    end

    {id, restore}
  end

  @spec unique_id() :: atom()
  defp unique_id do
    # Handler ids must be atoms, and each attach needs its own so that two
    # modules can never collide. Bounded by the number of capturing tests.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    String.to_atom("log_capture_#{System.unique_integer([:positive])}")
  end
end
