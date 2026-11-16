defmodule Tymeslot.Precommit.TimingsTest do
  use ExUnit.Case, async: true

  @moduletag :dev_support
  @moduletag :tmp_dir

  import ExUnit.CaptureIO

  alias Tymeslot.Precommit.Runner
  alias Tymeslot.Precommit.Timings

  @steps [
    {"compile", ["compile"], :dev},
    {"test", ["test"], :test},
    {"credo", ["credo", "--strict"], :dev}
  ]

  defp run(path, opts) do
    timings = Timings.start(["--affected"], path: path)
    capture_io(fn -> Runner.run(@steps, false, Timings.instrument(timings, @steps, opts)) end)
    path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp stub_capture(codes) do
    fn [command | _rest], _env, extra_env ->
      partition = List.keyfind(extra_env, "MIX_TEST_PARTITION", 0)
      {"", Map.get(codes, {command, partition && elem(partition, 1)}, 0)}
    end
  end

  test "records each step and each partition under its step's name", %{tmp_dir: dir} do
    path = Path.join(dir, "timings.jsonl")

    [line] =
      run(path,
        cmd: fn ["compile"], :dev -> 0 end,
        capture: stub_capture(%{}),
        suite_plan: fn -> %{partitions: 2, schedulers: 3} end
      )

    steps = Enum.map(line["steps"], &{&1["step"], &1["partition"], &1["code"]})

    assert Enum.sort(steps) ==
             Enum.sort([
               {"compile", nil, 0},
               {"test", "1", 0},
               {"test", "2", 0},
               {"credo", nil, 0}
             ])

    assert line["plan"] == %{"partitions" => 2, "schedulers" => 3}
    assert line["result"] == "passed"
    assert line["argv"] == ["--affected"]
    assert line["repo"] == "tymeslot"
    assert is_float(line["wall_s"])
    assert Enum.all?(line["steps"], &(is_float(&1["started_s"]) and is_float(&1["wall_s"])))
    assert is_float(line["cpu"]["gate_s"])
    assert line["machine"]["schedulers"] == System.schedulers_online()
  end

  test "a failing step marks the run failed, and runs append", %{tmp_dir: dir} do
    path = Path.join(dir, "timings.jsonl")
    opts = [cmd: fn ["compile"], :dev -> 0 end, suite_plan: fn -> nil end]

    run(path, [capture: stub_capture(%{}), on_results: fn _results -> :ok end] ++ opts)

    lines =
      try do
        run(path, [capture: stub_capture(%{{"credo", nil} => 4})] ++ opts)
      catch
        :exit, {:shutdown, 1} ->
          path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
      end

    assert Enum.map(lines, & &1["result"]) == ["passed", "failed"]
  end

  test "still calls the task's own on_results", %{tmp_dir: dir} do
    test_pid = self()

    run(Path.join(dir, "timings.jsonl"),
      cmd: fn ["compile"], :dev -> 0 end,
      capture: stub_capture(%{}),
      on_results: fn results -> send(test_pid, {:results, results}) end
    )

    assert_received {:results, [_ | _]}
  end

  test "starts a new file once the old one is past its size limit", %{tmp_dir: dir} do
    path = Path.join(dir, "timings.jsonl")
    File.write!(path, :binary.copy("x", 5_000_001))

    [line] = run(path, cmd: fn ["compile"], :dev -> 0 end, capture: stub_capture(%{}))

    assert line["result"] == "passed"
    assert File.stat!(path <> ".1").size == 5_000_001
  end

  test "with recording off, the runner's options pass through untouched" do
    opts = [suite_plan: fn -> nil end]
    assert Timings.instrument(nil, @steps, opts) == opts
  end

  describe "resolve_path/2" do
    test "an empty PRECOMMIT_TIMINGS_FILE turns recording off" do
      assert Timings.resolve_path("", "/state") == nil
    end

    test "an explicit file wins over the state directory" do
      assert Timings.resolve_path("/elsewhere/t.jsonl", "/state") == "/elsewhere/t.jsonl"
    end

    test "defaults to the XDG state directory, or ~/.local/state without one" do
      assert Timings.resolve_path(nil, "/state") == "/state/tymeslot/precommit_timings.jsonl"

      assert Timings.resolve_path(nil, nil) ==
               Path.join(System.user_home!(), ".local/state/tymeslot/precommit_timings.jsonl")

      assert Timings.resolve_path(nil, "") == Timings.resolve_path(nil, nil)
    end
  end
end
