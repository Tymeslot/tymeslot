defmodule Tymeslot.Workers.IntegrationHealthWorkerTest do
  use Tymeslot.DataCase, async: false
  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox

  alias Tymeslot.Integrations.HealthCheckMock
  alias Tymeslot.Workers.IntegrationHealthWorker

  setup :verify_on_exit!

  describe "perform/1 - argument validation" do
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

  describe "perform/1 - run_with_timeout" do
    test "returns :ok when perform_single_check succeeds" do
      expect(HealthCheckMock, :perform_single_check, fn :calendar, 42 -> :ok end)

      assert :ok =
               perform_job(IntegrationHealthWorker, %{
                 "type" => "calendar",
                 "integration_id" => 42
               })
    end

    test "returns :ok when perform_single_check returns an error (logs warning, does not fail)" do
      expect(HealthCheckMock, :perform_single_check, fn :video, 7 ->
        {:error, :connection_refused}
      end)

      assert :ok =
               perform_job(IntegrationHealthWorker, %{
                 "type" => "video",
                 "integration_id" => 7
               })
    end
  end

  describe "worker configuration" do
    test "has a 120-second job timeout" do
      assert IntegrationHealthWorker.job_timeout_ms() == 120_000
    end
  end
end
