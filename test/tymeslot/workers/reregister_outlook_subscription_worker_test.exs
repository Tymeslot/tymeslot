defmodule Tymeslot.Workers.ReregisterOutlookSubscriptionWorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import Mox
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.ReregisterOutlookSubscriptionWorker

  setup :verify_on_exit!

  describe "perform/1" do
    test "discards job when integration does not exist" do
      assert {:discard, "Integration not found"} =
               perform_job(ReregisterOutlookSubscriptionWorker, %{
                 "calendar_integration_id" => -1
               })
    end

    # `subscriptionRemoved`: the stored subscription is gone, so the first run
    # creates a replacement. A run the Oban lifeline repeats afterwards must
    # renew that replacement, not create a third subscription that would push
    # to us unrecorded until it expired.
    test "a rescued re-registration renews the replacement instead of creating another" do
      Application.put_env(:tymeslot, :webhook_base_url, "https://hook.example.com")
      on_exit(fn -> Application.delete_env(:tymeslot, :webhook_base_url) end)

      integration =
        insert(:calendar_integration,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid-token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
          graph_subscription_id: "graph-sub-removed",
          graph_client_state: "old-client-state",
          graph_subscription_expires_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
        )

      test_pid = self()

      # One POST at most: a second creation fails the test on exit.
      expect(Tymeslot.HTTPClientMock, :request, 3, fn
        :patch, url, _body, _headers, _opts ->
          send(test_pid, {:patched, url})

          if String.ends_with?(url, "/subscriptions/graph-sub-removed") do
            {:ok, %Req.Response{status: 404, body: Jason.encode!(%{"error" => %{}})}}
          else
            {:ok,
             %Req.Response{
               status: 200,
               body:
                 Jason.encode!(%{
                   "id" => "graph-sub-new",
                   "expirationDateTime" => "2030-06-05T10:00:00Z"
                 })
             }}
          end

        :post, url, _body, _headers, _opts ->
          assert String.ends_with?(url, "/subscriptions")

          {:ok,
           %Req.Response{
             status: 201,
             body:
               Jason.encode!(%{
                 "id" => "graph-sub-new",
                 "expirationDateTime" => "2030-06-03T10:00:00Z"
               })
           }}
      end)

      job =
        persisted_job(ReregisterOutlookSubscriptionWorker, %{
          "calendar_integration_id" => integration.id
        })

      assert :ok = ReregisterOutlookSubscriptionWorker.perform(job)
      assert :ok = ReregisterOutlookSubscriptionWorker.perform(job)

      assert_received {:patched, first_url}
      assert String.ends_with?(first_url, "/subscriptions/graph-sub-removed")
      assert_received {:patched, second_url}
      assert String.ends_with?(second_url, "/subscriptions/graph-sub-new")

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.graph_subscription_id == "graph-sub-new"
      assert reloaded.graph_subscription_expires_at == ~U[2030-06-05 10:00:00Z]
    end
  end
end
