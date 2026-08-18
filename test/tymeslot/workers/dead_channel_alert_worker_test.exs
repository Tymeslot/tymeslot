defmodule Tymeslot.Workers.DeadChannelAlertWorkerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers
  @moduletag :calendar

  import ExUnit.CaptureLog
  import Tymeslot.Factory

  alias Tymeslot.Workers.DeadChannelAlertWorker

  @alert_message "Calendar integration silent"

  describe "perform/1" do
    test "logs no alert when the database holds no integrations" do
      log = run_worker()

      refute log =~ @alert_message
      assert flagged_user_ids(log) == []
    end

    test "flags a silent google integration that has a recent confirmed meeting" do
      user = silent_google_integration()

      log = run_worker()

      assert log =~ @alert_message
      assert flagged_user_ids(log) == [user.id]
    end

    test "does not flag a google integration that received a recent notification" do
      flagged = silent_google_integration()
      quiet = insert(:user)

      quiet
      |> google_integration(last_google_notification_at: DateTime.utc_now())
      |> confirmed_meeting(quiet)

      assert flagged_user_ids(run_worker()) == [flagged.id]
    end

    test "does not flag a google integration with an expired channel" do
      flagged = silent_google_integration()
      quiet = insert(:user)

      quiet
      |> google_integration(google_channel_expires_at: DateTime.add(DateTime.utc_now(), -3_600))
      |> confirmed_meeting(quiet)

      assert flagged_user_ids(run_worker()) == [flagged.id]
    end

    test "does not flag a google integration that never had a channel id" do
      flagged = silent_google_integration()
      quiet = insert(:user)

      quiet
      |> google_integration(google_channel_id: nil, google_channel_expires_at: nil)
      |> confirmed_meeting(quiet)

      assert flagged_user_ids(run_worker()) == [flagged.id]
    end

    test "does not flag a google integration without a recent confirmed meeting" do
      flagged = silent_google_integration()
      quiet = insert(:user)
      google_integration(quiet, [])

      assert flagged_user_ids(run_worker()) == [flagged.id]
    end

    test "flags a silent outlook subscription and ignores one without a subscription id" do
      flagged = insert(:user)

      flagged
      |> outlook_integration([])
      |> confirmed_meeting(flagged)

      quiet = insert(:user)

      quiet
      |> outlook_integration(graph_subscription_id: nil, graph_subscription_expires_at: nil)
      |> confirmed_meeting(quiet)

      log = run_worker()

      assert log =~ @alert_message
      assert flagged_user_ids(log) == [flagged.id]
    end
  end

  defp run_worker do
    capture_log(fn -> assert :ok = perform_job(DeadChannelAlertWorker, %{}) end)
  end

  # The worker logs one warning per flagged integration, carrying the owning
  # user_id as structured metadata. Extracting those ids lets a test assert
  # both who was flagged and who was left alone in a single comparison.
  defp flagged_user_ids(log) do
    ~r/#{@alert_message}.*?user_id=(\d+)/
    |> Regex.scan(log)
    |> Enum.map(fn [_line, id] -> String.to_integer(id) end)
    |> Enum.sort()
  end

  defp silent_google_integration do
    user = insert(:user)

    user
    |> google_integration([])
    |> confirmed_meeting(user)

    user
  end

  defp google_integration(user, overrides) do
    defaults = [
      user: user,
      provider: "google",
      is_active: true,
      google_channel_id: unique_id("channel"),
      google_channel_expires_at: DateTime.add(DateTime.utc_now(), 7 * 86_400),
      last_google_notification_at: DateTime.add(DateTime.utc_now(), -48 * 3_600)
    ]

    insert(:calendar_integration, Keyword.merge(defaults, overrides))
  end

  defp outlook_integration(user, overrides) do
    defaults = [
      user: user,
      provider: "outlook",
      is_active: true,
      graph_subscription_id: unique_id("subscription"),
      graph_subscription_expires_at: DateTime.add(DateTime.utc_now(), 2 * 86_400),
      last_outlook_notification_at: DateTime.add(DateTime.utc_now(), -48 * 3_600)
    ]

    insert(:calendar_integration, Keyword.merge(defaults, overrides))
  end

  defp confirmed_meeting(integration, user) do
    insert(:meeting,
      organizer_user_id: user.id,
      calendar_integration_id: integration.id,
      start_time: DateTime.truncate(DateTime.add(DateTime.utc_now(), -24 * 3_600), :second),
      end_time: DateTime.truncate(DateTime.add(DateTime.utc_now(), -23 * 3_600), :second),
      status: "confirmed"
    )
  end

  defp unique_id(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
