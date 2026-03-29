defmodule Tymeslot.Workers.IntegrationHealthWorkerTest do
  use Tymeslot.DataCase, async: true
  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  alias Tymeslot.Workers.IntegrationHealthWorker

  describe "perform/1" do
    test "discards job with missing args" do
      assert {:discard, "Invalid arguments"} = perform_job(IntegrationHealthWorker, %{})
    end

    test "discards job with invalid type string" do
      assert {:discard, "Invalid integration type"} =
               perform_job(IntegrationHealthWorker, %{
                 "type" => "webhook",
                 "integration_id" => 1
               })
    end

    test "discards job with non-string type" do
      assert {:discard, "Invalid arguments"} =
               perform_job(IntegrationHealthWorker, %{
                 "type" => 123,
                 "integration_id" => 1
               })
    end
  end
end
