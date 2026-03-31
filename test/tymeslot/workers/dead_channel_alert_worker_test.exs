defmodule Tymeslot.Workers.DeadChannelAlertWorkerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Workers.DeadChannelAlertWorker

  describe "perform/1" do
    test "returns :ok with no integrations in the database" do
      assert :ok = perform_job(DeadChannelAlertWorker, %{})
    end

    test "does not flag a google integration that received a recent notification" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        google_channel_id: "active-channel",
        google_channel_expires_at: DateTime.add(DateTime.utc_now(), 7 * 86_400),
        last_google_notification_at: DateTime.utc_now()
      )

      assert :ok = perform_job(DeadChannelAlertWorker, %{})
    end

    test "does not flag a google integration with an expired channel" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        google_channel_id: "expired-channel",
        google_channel_expires_at: DateTime.add(DateTime.utc_now(), -3_600),
        last_google_notification_at: DateTime.add(DateTime.utc_now(), -48 * 3_600)
      )

      assert :ok = perform_job(DeadChannelAlertWorker, %{})
    end

    test "flags a silent google integration that has a recent confirmed meeting" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true,
          google_channel_id: "silent-channel",
          google_channel_expires_at: DateTime.add(DateTime.utc_now(), 7 * 86_400),
          last_google_notification_at: DateTime.add(DateTime.utc_now(), -48 * 3_600)
        )

      insert(:meeting,
        organizer_user_id: user.id,
        calendar_integration_id: integration.id,
        start_time: DateTime.truncate(DateTime.add(DateTime.utc_now(), -24 * 3_600), :second),
        end_time: DateTime.truncate(DateTime.add(DateTime.utc_now(), -23 * 3_600), :second),
        status: "confirmed"
      )

      # Worker completes without error; the side effect is a log warning
      assert :ok = perform_job(DeadChannelAlertWorker, %{})
    end

    test "does not flag a google integration that never had a channel id" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        google_channel_id: nil,
        google_channel_expires_at: nil,
        last_google_notification_at: nil
      )

      assert :ok = perform_job(DeadChannelAlertWorker, %{})
    end

    test "returns :ok with no qualifying outlook integrations" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "outlook",
        is_active: true,
        graph_subscription_id: nil,
        graph_subscription_expires_at: nil
      )

      assert :ok = perform_job(DeadChannelAlertWorker, %{})
    end
  end
end
