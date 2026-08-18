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
  end
end
