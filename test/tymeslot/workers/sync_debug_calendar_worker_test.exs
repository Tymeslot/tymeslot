defmodule Tymeslot.Workers.SyncDebugCalendarWorkerTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.Factory

  alias Tymeslot.Workers.SyncDebugCalendarWorker

  defp subscribe_to_sync_topic(user_id) do
    Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user_id}")
  end

  describe "perform/1" do
    test "broadcasts sync completion so the refresh spinner clears immediately" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "debug", is_active: true)
      :ok = subscribe_to_sync_topic(user.id)

      # The in-memory debug sync runs to completion in milliseconds. The bug it
      # guards against: without the completion broadcast the connected grid only
      # stops syncing via its 30-second fallback timer, so a refresh appears to
      # hang for half a minute.
      assert :ok =
               perform_job(SyncDebugCalendarWorker, %{
                 "calendar_integration_id" => integration.id
               })

      assert_receive {:calendar_sync_complete, user_id, integration_id}
      assert user_id == user.id
      assert integration_id == integration.id
    end

    test "discards the job when the integration no longer exists" do
      assert {:discard, _reason} =
               perform_job(SyncDebugCalendarWorker, %{"calendar_integration_id" => -1})
    end
  end
end
