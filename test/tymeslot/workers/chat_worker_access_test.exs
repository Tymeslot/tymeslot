defmodule Tymeslot.Workers.ChatWorkerAccessTest do
  @moduledoc """
  What the Slack and Telegram delivery workers do with each answer to the
  organiser's automations access check, which they share through
  `Tymeslot.Workers.MeetingNotificationJob.feature_gate/1`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :notifications

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Test.ProcessAccessChecker
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker}

  setup :verify_on_exit!

  setup do
    setup_config(:tymeslot,
      feature_access_checker: ProcessAccessChecker,
      slack_notifications_allowed: true,
      telegram_notifications_allowed: true,
      telegram_shared_bot: false,
      http_client_module: Tymeslot.HTTPClientMock
    )

    # No answer reaches the provider.
    expect(Tymeslot.HTTPClientMock, :post, 0, fn _url, _body, _headers, _opts -> :unused end)

    user = insert(:user)
    %{user: user, meeting: insert(:meeting, organizer_user_id: user.id)}
  end

  for {factory, worker, schema} <- [
        {:slack_integration, SlackWorker, SlackIntegrationSchema},
        {:telegram_integration, TelegramWorker, TelegramIntegrationSchema}
      ] do
    describe "#{inspect(worker)} and the automations access check" do
      setup %{user: user} do
        %{integration: insert(unquote(factory), user: user)}
      end

      for reason <- [:insufficient_plan, :pro_required, :stripe_required] do
        # The integration pauses with the plan and resumes with it: the job
        # is dropped, the row left active for the next plan that covers it.
        test "discards the job and leaves the integration on when the plan answers #{reason}",
             %{integration: integration, meeting: meeting} do
          ProcessAccessChecker.answer({:error, unquote(reason)})

          assert {:discard, "Insufficient plan"} =
                   perform_job(unquote(worker), args(integration, meeting))

          updated = Repo.get!(unquote(schema), integration.id)
          assert updated.is_active
          assert is_nil(updated.disabled_at)
          assert is_nil(updated.disabled_reason)
        end
      end

      test "leaves a paused integration paused when the plan is revoked", %{
        user: user,
        meeting: meeting
      } do
        paused = insert(unquote(factory), user: user, is_active: false)
        ProcessAccessChecker.answer({:error, :insufficient_plan})

        assert {:discard, "Insufficient plan"} =
                 perform_job(unquote(worker), args(paused, meeting))

        updated = Repo.get!(unquote(schema), paused.id)
        refute updated.is_active
        assert is_nil(updated.disabled_at)
        assert is_nil(updated.disabled_reason)
      end

      test "keeps the reason an integration was already disabled for", %{
        user: user,
        meeting: meeting
      } do
        disabled_at = DateTime.add(DateTime.utc_now(:second), -3600, :second)

        disabled =
          insert(unquote(factory),
            user: user,
            is_active: false,
            disabled_at: disabled_at,
            disabled_reason: "bot_blocked"
          )

        ProcessAccessChecker.answer({:error, :insufficient_plan})

        assert {:discard, "Insufficient plan"} =
                 perform_job(unquote(worker), args(disabled, meeting))

        updated = Repo.get!(unquote(schema), disabled.id)
        assert updated.disabled_reason == "bot_blocked"
        assert DateTime.compare(updated.disabled_at, disabled_at) == :eq
      end

      test "discards without switching the integration off when automations are off", %{
        integration: integration,
        meeting: meeting
      } do
        ProcessAccessChecker.answer({:error, :feature_disabled})

        assert {:discard, "Automations are switched off"} =
                 perform_job(unquote(worker), args(integration, meeting))

        updated = Repo.get!(unquote(schema), integration.id)
        assert updated.is_active
        assert is_nil(updated.disabled_at)
      end

      test "retries, leaving the integration alone, when the access check fails", %{
        integration: integration,
        meeting: meeting
      } do
        ProcessAccessChecker.answer({:error, :checker_unavailable})

        assert {:error, :feature_access_checker_failed} =
                 perform_job(unquote(worker), args(integration, meeting))

        updated = Repo.get!(unquote(schema), integration.id)
        assert updated.is_active
        assert updated.failure_count == 0
      end
    end
  end

  defp args(integration, meeting) do
    %{
      "integration_id" => integration.id,
      "event_type" => "meeting.created",
      "meeting_id" => meeting.id
    }
  end
end
