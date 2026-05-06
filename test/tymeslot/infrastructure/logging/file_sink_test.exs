defmodule Tymeslot.Infrastructure.Logging.FileSinkTest do
  # async: false — the test mutates the global :logger handler list and
  # process env vars; running concurrently with other logger-touching tests
  # would race.
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  require Logger
  alias Tymeslot.Infrastructure.Logging.FileSink

  setup do
    original = System.get_env("LOG_FILE_PATH")
    original_deployment = System.get_env("DEPLOYMENT_TYPE")

    on_exit(fn ->
      FileSink.detach()
      restore_env("LOG_FILE_PATH", original)
      restore_env("DEPLOYMENT_TYPE", original_deployment)
    end)

    :ok
  end

  describe "attach/0" do
    test "is a no-op when LOG_FILE_PATH is unset and not on cloudron" do
      System.delete_env("LOG_FILE_PATH")
      System.delete_env("DEPLOYMENT_TYPE")

      assert :ok = FileSink.attach()
      assert {:error, {:not_found, _id}} = :logger.get_handler_config(FileSink.handler_id())
    end

    test "is a no-op when LOG_FILE_PATH is the empty string" do
      System.put_env("LOG_FILE_PATH", "")
      System.delete_env("DEPLOYMENT_TYPE")

      assert :ok = FileSink.attach()
      assert {:error, {:not_found, _id}} = :logger.get_handler_config(FileSink.handler_id())
    end

    test "installs a logger_std_h handler when LOG_FILE_PATH is set" do
      tmp =
        Path.join(System.tmp_dir!(), "tymeslot_file_sink_#{System.unique_integer([:positive])}")

      log_path = Path.join(tmp, "app.log")
      System.put_env("LOG_FILE_PATH", log_path)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert :ok = FileSink.attach()

      assert {:ok, %{module: :logger_std_h, config: cfg}} =
               :logger.get_handler_config(FileSink.handler_id())

      assert cfg.file == String.to_charlist(log_path)
      assert cfg.compress_on_rotate == true
      assert is_integer(cfg.max_no_bytes) and cfg.max_no_bytes > 0
      assert is_integer(cfg.max_no_files) and cfg.max_no_files > 0
      # Drop-on-overload, never kill the handler — see file_sink.ex contract.
      assert cfg.overload_kill_enable == false
      assert File.dir?(tmp), "log directory should be created"
    end

    test "honours LOG_FILE_MAX_BYTES and LOG_FILE_MAX_FILES env vars" do
      tmp =
        Path.join(System.tmp_dir!(), "tymeslot_file_sink_#{System.unique_integer([:positive])}")

      log_path = Path.join(tmp, "app.log")
      System.put_env("LOG_FILE_PATH", log_path)
      System.put_env("LOG_FILE_MAX_BYTES", "1234567")
      System.put_env("LOG_FILE_MAX_FILES", "7")

      on_exit(fn ->
        File.rm_rf!(tmp)
        System.delete_env("LOG_FILE_MAX_BYTES")
        System.delete_env("LOG_FILE_MAX_FILES")
      end)

      assert :ok = FileSink.attach()
      assert {:ok, %{config: cfg}} = :logger.get_handler_config(FileSink.handler_id())
      assert cfg.max_no_bytes == 1_234_567
      assert cfg.max_no_files == 7
    end

    test "falls back to defaults when env vars are not positive integers" do
      tmp =
        Path.join(System.tmp_dir!(), "tymeslot_file_sink_#{System.unique_integer([:positive])}")

      log_path = Path.join(tmp, "app.log")
      System.put_env("LOG_FILE_PATH", log_path)
      System.put_env("LOG_FILE_MAX_BYTES", "not-a-number")
      System.put_env("LOG_FILE_MAX_FILES", "0")

      on_exit(fn ->
        File.rm_rf!(tmp)
        System.delete_env("LOG_FILE_MAX_BYTES")
        System.delete_env("LOG_FILE_MAX_FILES")
      end)

      assert :ok = FileSink.attach()
      assert {:ok, %{config: cfg}} = :logger.get_handler_config(FileSink.handler_id())
      assert cfg.max_no_bytes == 10_000_000
      assert cfg.max_no_files == 30
    end

    test "is idempotent — repeated calls reinstall the handler cleanly" do
      tmp =
        Path.join(System.tmp_dir!(), "tymeslot_file_sink_#{System.unique_integer([:positive])}")

      log_path = Path.join(tmp, "app.log")
      System.put_env("LOG_FILE_PATH", log_path)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert :ok = FileSink.attach()
      assert :ok = FileSink.attach()
      assert {:ok, _config} = :logger.get_handler_config(FileSink.handler_id())
    end

    test "writes log output to the configured file" do
      tmp =
        Path.join(System.tmp_dir!(), "tymeslot_file_sink_#{System.unique_integer([:positive])}")

      log_path = Path.join(tmp, "app.log")
      System.put_env("LOG_FILE_PATH", log_path)
      on_exit(fn -> File.rm_rf!(tmp) end)

      assert :ok = FileSink.attach()

      Logger.error("file sink probe", probe_id: "abc-123")
      :logger_std_h.filesync(FileSink.handler_id())

      contents = File.read!(log_path)
      assert contents =~ "file sink probe"
      assert contents =~ "abc-123"
    end

    test "returns {:error, _} and leaves handler uninstalled when the cloudron default path directory cannot be created" do
      System.put_env("DEPLOYMENT_TYPE", "cloudron")
      System.delete_env("LOG_FILE_PATH")

      assert {:error, _reason} = FileSink.attach()
      assert {:error, {:not_found, _id}} = :logger.get_handler_config(FileSink.handler_id())
    end

    test "returns {:error, _} and leaves handler uninstalled when the log directory cannot be created" do
      System.put_env("LOG_FILE_PATH", "/proc/impossible/app.log")

      assert {:error, _reason} = FileSink.attach()
      assert {:error, {:not_found, _id}} = :logger.get_handler_config(FileSink.handler_id())
    end
  end

  describe "detach/0" do
    test "removes the handler if installed" do
      tmp =
        Path.join(System.tmp_dir!(), "tymeslot_file_sink_#{System.unique_integer([:positive])}")

      log_path = Path.join(tmp, "app.log")
      System.put_env("LOG_FILE_PATH", log_path)
      on_exit(fn -> File.rm_rf!(tmp) end)

      :ok = FileSink.attach()
      assert :ok = FileSink.detach()
      assert {:error, {:not_found, _id}} = :logger.get_handler_config(FileSink.handler_id())
    end

    test "is safe to call when no handler is installed" do
      assert :ok = FileSink.detach()
      assert :ok = FileSink.detach()
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
