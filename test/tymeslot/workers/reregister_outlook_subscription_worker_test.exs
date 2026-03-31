defmodule Tymeslot.Workers.ReregisterOutlookSubscriptionWorkerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  alias Tymeslot.Workers.ReregisterOutlookSubscriptionWorker

  describe "perform/1" do
    test "discards job when integration does not exist" do
      assert {:discard, "Integration not found"} =
               perform_job(ReregisterOutlookSubscriptionWorker, %{
                 "calendar_integration_id" => -1
               })
    end

    test "enqueues with correct worker configuration" do
      changeset =
        ReregisterOutlookSubscriptionWorker.new(%{calendar_integration_id: 123})

      assert changeset.changes.queue == "calendar_events"
      assert changeset.changes.max_attempts == 3
    end
  end
end
