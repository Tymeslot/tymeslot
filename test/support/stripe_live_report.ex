defmodule Tymeslot.StripeLiveReport do
  @moduledoc """
  Collects what the Stripe live suite did and writes it to
  `tmp/stripe_live/report.json` and `report.md`, so a later session can triage
  without re-running. It also holds the objects to clean up and, when
  recording, the live responses to write as fixtures.

  The report never carries the key, request bodies or headers. The agent is
  started with `Agent.start/1`, unlinked, because `setup_all` and the tests
  run in different processes and the report is written after the last test.
  """

  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.StripeLiveContract

  @dir "tmp/stripe_live"
  @fixtures_root Path.expand("fixtures/stripe/api", __DIR__)

  @type report :: pid()

  @spec start() :: report()
  def start do
    {:ok, pid} = Agent.start(fn -> %{steps: [], tracked: [], captures: []} end)
    pid
  end

  @spec record(report(), map()) :: :ok
  def record(report, step) do
    Agent.update(report, &%{&1 | steps: [step | &1.steps]})
  end

  @spec steps(report()) :: [map()]
  def steps(report), do: report |> Agent.get(& &1.steps) |> Enum.reverse()

  @doc "Remembers an object for cleanup."
  @spec track(report(), atom(), String.t()) :: :ok
  def track(report, kind, id) do
    Agent.update(report, &%{&1 | tracked: [{kind, id} | &1.tracked]})
  end

  @spec tracked(report()) :: [{atom(), String.t()}]
  def tracked(report), do: Agent.get(report, & &1.tracked)

  @doc "Keeps a live response, to be written as the named fixture when recording."
  @spec capture(report(), String.t(), map()) :: :ok
  def capture(report, fixture, live) do
    Agent.update(report, &%{&1 | captures: [{fixture, live} | &1.captures]})
  end

  @doc """
  Writes the report and, when `recorded?`, the captured fixtures. The report
  goes first; a failure while recording is itself recorded in it.
  """
  @spec write!(report(), boolean()) :: :ok
  def write!(report, recorded?) do
    write_report!(report, recorded?)

    if recorded? do
      try do
        write_fixtures!(Agent.get(report, & &1.captures))
      rescue
        exception ->
          record(report, %{
            flow: "recording",
            operation: "write fixtures",
            status: :failed,
            duration_ms: 0,
            error: %{type: "exception", message: Exception.message(exception)},
            drift: nil,
            note: "fixtures were not (fully) written"
          })

          write_report!(report, recorded?)
      end
    end

    :ok
  end

  defp write_report!(report, recorded?) do
    steps = steps(report)
    File.mkdir_p!(@dir)
    json = report_map(steps, recorded?)
    File.write!(Path.join(@dir, "report.json"), Jason.encode!(json, pretty: true))
    File.write!(Path.join(@dir, "report.md"), markdown(json, steps))
  end

  defp report_map(steps, recorded?) do
    %{
      "run_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "api_version" => Stripe.api_version(),
      "key_mode" => "test",
      "recorded" => recorded?,
      "steps" => steps,
      "summary" =>
        Map.new(~w(ok failed skipped), fn status ->
          {status, Enum.count(steps, &(to_string(&1.status) == status))}
        end)
    }
  end

  defp markdown(%{"summary" => s, "run_at" => run_at, "api_version" => version}, steps) do
    flows = steps |> Enum.map(& &1.flow) |> Enum.uniq()

    IO.iodata_to_binary([
      "# Stripe live suite\n\n",
      "Run at #{run_at}, API version #{version}: #{s["ok"]} ok, #{s["failed"]} failed, ",
      "#{s["skipped"]} skipped.\n",
      Enum.map(flows, &flow_table(&1, Enum.filter(steps, fn step -> step.flow == &1 end))),
      skipped_section(steps)
    ])
  end

  defp flow_table(flow, steps) do
    rows =
      Enum.map(steps, fn step ->
        err = step.error || %{}

        cells = [
          step.operation,
          step.status,
          "#{step.duration_ms} ms",
          error_cell(step, err),
          drift_cell(step)
        ]

        "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |\n"
      end)

    [
      "\n## #{flow}\n\n",
      "| Operation | Status | Duration | Error (type / code / status / request) | Drift |\n",
      "|---|---|---|---|---|\n",
      rows
    ]
  end

  defp error_cell(step, err) do
    base =
      [err[:type], err[:code], err[:decline_code], err[:status], err[:request_id]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" / ")

    if step.status == :failed do
      detail = [err[:message], err[:param] && "param: #{err[:param]}"]
      Enum.join([base | Enum.reject(detail, &(&1 in [nil, false]))], " | ")
    else
      base
    end
  end

  defp drift_cell(%{drift: [_first | _rest] = drift}), do: Enum.join(drift, ", ")
  defp drift_cell(_step), do: ""

  defp cell(value),
    do: value |> to_string() |> String.replace("|", "\\|") |> String.replace("\n", " ")

  defp skipped_section(steps) do
    case Enum.filter(steps, &(&1.status == :skipped)) do
      [] ->
        []

      skipped ->
        [
          "\n## Skipped\n\n",
          Enum.map(skipped, &"- #{&1.flow}: #{&1.operation}: #{&1.note}\n"),
          connect_limitation(skipped)
        ]
    end
  end

  # The Express account the connect flow creates is never onboarded. Stripe's
  # sandbox may accept its charges before `card_payments` is active, but is
  # not required to, so a skip of a connect payment step can be this.
  defp connect_limitation(skipped) do
    if Enum.any?(skipped, &(&1.flow == "connect" and &1.operation =~ "(connect)")) do
      "\nThe connect payment steps use an Express account that is created but never onboarded. " <>
        "Stripe's sandbox may refuse its charges until `card_payments` is active; if a reason above " <>
        "says so, the step needs an onboarded test account, not a code change.\n"
    else
      []
    end
  end

  defp write_fixtures!(captures) do
    dir = Path.join(@fixtures_root, Stripe.api_version())
    captures = Enum.reverse(captures)

    ids =
      Enum.reduce(captures, %{}, fn {name, live}, acc ->
        fixture = dir |> Path.join(name <> ".json") |> File.read!() |> Jason.decode!()
        Map.merge(acc, StripeLiveContract.id_map(fixture, live))
      end)

    for {name, live} <- captures do
      content = live |> StripeLiveContract.sanitise(ids) |> Jason.encode!(pretty: true)
      File.write!(Path.join(dir, name <> ".json"), content <> "\n")
    end

    mark_recorded!(captures |> Enum.map(&elem(&1, 0)) |> Enum.uniq())
  end

  defp mark_recorded!(names) do
    readme = Path.join(@fixtures_root, "README.md")
    today = Date.to_iso8601(Date.utc_today())
    File.write!(readme, StripeLiveContract.mark_recorded(File.read!(readme), names, today))
  end
end
