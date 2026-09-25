defmodule Tymeslot.Infrastructure.ObanRescueTest do
  use Tymeslot.DataCase, async: true

  @moduletag :infrastructure
  @moduletag :workers

  alias Config.Reader
  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Changeset
  alias Oban.Config
  alias Oban.Lifeline
  alias Oban.Peer
  alias Oban.Peers.Isolated
  alias Oban.Registry
  alias Tymeslot.Infrastructure.ObanRescue
  alias Tymeslot.Repo

  # Reports each run to the test process, so "rescued, and ran once" can be
  # read off the mailbox rather than inferred from the job row.
  defmodule RescuedWorker do
    use Oban.Worker, queue: :default, max_attempts: 3

    @impl Oban.Worker
    def perform(%Oban.Job{}) do
      send(:oban_rescue_test, :ran)

      :ok
    end
  end

  # The rescue Oban performs for us, driven directly rather than waited for:
  # the plugin only rescues as the cluster leader, and the test instance is
  # deliberately never one, so the run needs a leader peer of its own.
  defp rescue_jobs(rescue_after) do
    # One instance per test, so a peer left over from the previous one cannot
    # answer for this one.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"oban_rescue_#{System.unique_integer([:positive])}"

    conf =
      Config.new(
        repo: Repo,
        name: name,
        peer: {Isolated, [leader?: true]},
        queues: []
      )

    {:ok, peer} =
      Isolated.start_link(
        conf: conf,
        name: Registry.via(name, Peer),
        leader?: true
      )

    {:ok, lifeline} =
      Lifeline.start_link(
        conf: conf,
        rescue_after: rescue_after,
        interval: :timer.hours(1)
      )

    Sandbox.allow(Repo, self(), peer)
    Sandbox.allow(Repo, self(), lifeline)

    send(lifeline, :rescue)

    # The plugin rescues inside the `:rescue` message it was just sent, so
    # reading its state waits for that work to finish.
    :sys.get_state(lifeline)

    :ok
  end

  defp abandoned_job(executing_for, opts \\ []) do
    attempted_at = DateTime.add(DateTime.utc_now(), -executing_for, :minute)

    %{}
    |> RescuedWorker.new(Keyword.take(opts, [:max_attempts]))
    |> Oban.insert!()
    |> Changeset.change(
      state: "executing",
      attempted_at: attempted_at,
      attempt: Keyword.get(opts, :attempt, 1)
    )
    |> Repo.update!()
  end

  describe "the rescue the production configuration relies on" do
    setup do
      Process.register(self(), :oban_rescue_test)

      :ok
    end

    test "returns a job abandoned past the rescue window to available, and runs it once" do
      job = abandoned_job(90)

      assert :ok = rescue_jobs(:timer.minutes(60))

      assert Repo.get(Oban.Job, job.id).state == "available"
      assert %{success: 1} = Oban.drain_queue(queue: :default)
      assert_received :ran
      refute_received :ran
    end

    test "leaves a job still inside the rescue window executing" do
      job = abandoned_job(30)

      assert :ok = rescue_jobs(:timer.minutes(60))

      assert Repo.get(Oban.Job, job.id).state == "executing"
      assert %{success: 0} = Oban.drain_queue(queue: :default)
      refute_received :ran
    end

    # The other half of the bargain, and the reason a worker declaring
    # `max_attempts: 1` gains nothing from the lifeline: its job is already out
    # of attempts while it executes, so an interrupted run is dropped rather
    # than retried.
    test "discards an abandoned job with no attempts left" do
      job = abandoned_job(90, max_attempts: 1, attempt: 1)

      assert :ok = rescue_jobs(:timer.minutes(60))

      assert Repo.get(Oban.Job, job.id).state == "discarded"
      refute_received :ran
    end
  end

  describe "check/1" do
    test "accepts a window clear of both the longest job and the discard sweep" do
      assert ObanRescue.check(lifeline: [rescue_after: {6, :hours}]) == :ok
    end

    test "accepts a window given in milliseconds" do
      assert ObanRescue.check(lifeline: [rescue_after: :timer.hours(6)]) == :ok
    end

    test "reads the {module, options} shape of the service" do
      assert ObanRescue.check(lifeline: {Lifeline, [rescue_after: {6, :hours}]}) == :ok
    end

    test "reports a configuration carrying no lifeline at all" do
      assert ObanRescue.check(repo: Tymeslot.Repo) == :missing
      assert ObanRescue.check(lifeline: false) == :missing
    end

    test "flags a window that would re-run jobs still working" do
      assert {:rescues_too_soon, _ms} = ObanRescue.check(lifeline: [rescue_after: {30, :minutes}])
    end

    # Named as a bare module the plugin runs on Oban's own default of an hour,
    # which is well inside the longest job this codebase can legitimately run.
    test "flags a lifeline left on Oban's default window" do
      assert {:rescues_too_soon, _ms} = ObanRescue.check(lifeline: Lifeline)
    end

    test "flags a window the maintenance sweep discards a job ahead of" do
      too_late = ObanRescue.discard_after_hours()

      assert {:rescues_after_discard, _ms} =
               ObanRescue.check(lifeline: [rescue_after: {too_late, :hours}])
    end
  end

  # The production block in `runtime.exs` wants the production environment and
  # cannot be read back here, which is what the boot-time warning covers. The
  # development block carries the same lifeline for the same reasons, so it is
  # the one a test can hold to it.
  describe "the project's own configuration" do
    test "configures a lifeline this module considers safe" do
      config =
        [__DIR__, "..", "..", "..", "config", "dev.exs"]
        |> Path.join()
        |> Path.expand()
        |> Reader.read!(env: :dev, target: :host)
        |> get_in([:tymeslot, Oban])

      assert ObanRescue.check(config) == :ok
    end
  end
end
