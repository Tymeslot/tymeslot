defmodule Tymeslot.Workers.DeliveryClaimsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :infrastructure

  alias Oban.Job
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.DeliveryClaims.DeliveryClaimQueries
  alias Tymeslot.Workers.DeliveryClaims.DeliveryClaimSchema

  setup do
    {:ok, job} = Oban.insert(Job.new(%{}, worker: "Example.Worker", queue: :default))

    {:ok, job: job}
  end

  # Counts how many times an effect actually ran, in the test process.
  defp counting_effect(result) do
    fn ->
      send(self(), :effect_ran)
      result
    end
  end

  describe "once/3" do
    test "runs the effect on the first execution and skips it on a rescued one", %{job: job} do
      assert :ok = DeliveryClaims.once(job, "email", counting_effect(:ok))
      assert :ok = DeliveryClaims.once(job, "email", counting_effect(:ok))

      assert_received :effect_ran
      refute_received :effect_ran
    end

    test "claims each key separately", %{job: job} do
      assert :ok = DeliveryClaims.once(job, "participant:1", counting_effect(:ok))
      assert :ok = DeliveryClaims.once(job, "participant:2", counting_effect(:ok))

      assert_received :effect_ran
      assert_received :effect_ran
    end

    test "keeps the claim on an {:ok, _} result", %{job: job} do
      assert {:ok, :sent} = DeliveryClaims.once(job, "email", counting_effect({:ok, :sent}))
      assert DeliveryClaimQueries.claimed?(job.id, "email")
    end

    test "releases the claim when the effect fails, so a retry performs it", %{job: job} do
      assert {:error, :smtp_down} =
               DeliveryClaims.once(job, "email", counting_effect({:error, :smtp_down}))

      refute DeliveryClaimQueries.claimed?(job.id, "email")

      assert :ok = DeliveryClaims.once(job, "email", counting_effect(:ok))
      assert_received :effect_ran
      assert_received :effect_ran
    end

    test "releases the claim on a snooze", %{job: job} do
      assert {:snooze, 30} = DeliveryClaims.once(job, "email", fn -> {:snooze, 30} end)
      refute DeliveryClaimQueries.claimed?(job.id, "email")
    end

    test "releases the claim when the effect raises, and re-raises", %{job: job} do
      assert_raise RuntimeError, "boom", fn ->
        DeliveryClaims.once(job, "email", fn -> raise "boom" end)
      end

      refute DeliveryClaimQueries.claimed?(job.id, "email")
    end

    test "runs unguarded for a job with no id" do
      job = %Job{id: nil}

      assert :ok = DeliveryClaims.once(job, "email", counting_effect(:ok))
      assert :ok = DeliveryClaims.once(job, "email", counting_effect(:ok))

      assert_received :effect_ran
      assert_received :effect_ran
      assert Repo.aggregate(DeliveryClaimSchema, :count) == 0
    end
  end

  describe "prune_orphaned/0" do
    test "deletes the claims of pruned jobs and keeps those of live ones", %{job: job} do
      {:ok, pruned_job} =
        Oban.insert(Job.new(%{}, worker: "Example.Worker", queue: :default))

      assert :ok = DeliveryClaims.once(job, "email", fn -> :ok end)
      assert :ok = DeliveryClaims.once(pruned_job, "email", fn -> :ok end)

      Repo.delete!(pruned_job)

      assert DeliveryClaims.prune_orphaned() == 1
      assert DeliveryClaimQueries.claimed?(job.id, "email")
      refute DeliveryClaimQueries.claimed?(pruned_job.id, "email")
    end
  end
end
