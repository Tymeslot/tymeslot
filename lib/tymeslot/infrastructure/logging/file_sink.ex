defmodule Tymeslot.Infrastructure.Logging.FileSink do
  @moduledoc """
  Adds a rotating-file handler to `:logger` so structured JSON logs survive
  past stdout. Purely additive — the default stdout handler continues to
  emit the same stream platform dashboards (Cloudron, `docker logs`, ...)
  rely on, so no operator-facing behaviour is removed.

  Configured via env vars (all optional):

  | Var | Default | Notes |
  |-----|---------|-------|
  | `LOG_FILE_PATH` | `/app/data/logs/app.log` on cloudron, unset elsewhere | Sink stays disabled when both this and the cloudron default resolve to nil |
  | `LOG_FILE_MAX_BYTES` | `10_000_000` (10 MB) | Per file before rotation |
  | `LOG_FILE_MAX_FILES` | `30` | Rotated files kept (≈30 days at typical volumes) |

  Rotated files are gzipped on rotation — `app.log.0.gz`, `app.log.1.gz`, ...
  Total disk use is bounded at `LOG_FILE_MAX_BYTES * (LOG_FILE_MAX_FILES + 1)`,
  i.e. ≈310 MB at the defaults.
  """

  require Logger

  alias LoggerJSON.Formatters.Basic, as: BasicFormatter

  @handler_id :tymeslot_file_sink

  @doc """
  Resolves config from env vars and installs the rotating-file handler.

  Returns `:ok` (handler installed or sink intentionally disabled) or
  `{:error, reason}` when the configured directory cannot be created.
  Idempotent — safe to call on application restart inside the same BEAM.
  """
  @spec attach() :: :ok | {:error, term()}
  def attach do
    case resolve_path() do
      nil -> :ok
      path -> do_attach(path)
    end
  end

  @doc """
  Removes the handler if installed. Used by tests.
  """
  @spec detach() :: :ok
  def detach do
    _previous = :logger.remove_handler(@handler_id)
    :ok
  end

  @doc """
  Returns the handler id so tests can inspect `:logger.get_handler_config/1`.
  """
  @spec handler_id() :: atom()
  def handler_id, do: @handler_id

  defp resolve_path do
    case System.get_env("LOG_FILE_PATH") do
      nil -> cloudron_default_path()
      "" -> nil
      path -> path
    end
  end

  defp cloudron_default_path do
    if System.get_env("DEPLOYMENT_TYPE") == "cloudron" do
      "/app/data/logs/app.log"
    end
  end

  defp do_attach(path) do
    dir = Path.dirname(path)

    case File.mkdir_p(dir) do
      :ok ->
        install_handler(path)

      {:error, reason} = error ->
        Logger.warning("File log sink disabled: cannot create log directory",
          path: dir,
          reason: inspect(reason)
        )

        error
    end
  end

  defp install_handler(path) do
    config = %{
      config: %{
        file: String.to_charlist(path),
        max_no_bytes: integer_env("LOG_FILE_MAX_BYTES", 10_000_000),
        max_no_files: integer_env("LOG_FILE_MAX_FILES", 30),
        compress_on_rotate: true,
        file_check: 5_000,
        # Failure-mode contract: under sustained overload, drop messages —
        # never kill the handler. A dead file sink loses logs forever (until
        # the next reattach); a dropping one loses a burst and recovers.
        overload_kill_enable: false
      },
      formatter: BasicFormatter.new(metadata: {:all_except, [:conn, :socket, :mfa, :pid, :gl]})
    }

    _previous = :logger.remove_handler(@handler_id)

    case :logger.add_handler(@handler_id, :logger_std_h, config) do
      :ok ->
        Logger.info("File log sink active",
          path: path,
          max_no_bytes: config.config.max_no_bytes,
          max_no_files: config.config.max_no_files
        )

        :ok

      {:error, reason} = error ->
        Logger.warning("File log sink could not be installed", reason: inspect(reason))
        error
    end
  end

  defp integer_env(var, default) do
    case System.get_env(var) do
      nil ->
        default

      str ->
        case Integer.parse(str) do
          {n, ""} when n > 0 -> n
          _other -> default
        end
    end
  end
end
