defmodule Tymeslot.Notifications.ChannelFanoutTest do
  use Tymeslot.DataCase, async: false

  @moduletag :notifications
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Notifications.ChannelFanout
  alias Tymeslot.Slack
  alias Tymeslot.Test.{LogCapture, ProcessAccessChecker}
  alias Tymeslot.Webhooks
  alias Tymeslot.Webhooks.WebhookSchema
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker, WebhookWorker}

  # Every channel, with the factory that subscribes an integration of it and
  # the job argument naming that integration.
  @channels [
    {:webhook, WebhookWorker, "webhook_id"},
    {:telegram_integration, TelegramWorker, "integration_id"},
    {:slack_integration, SlackWorker, "integration_id"}
  ]

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      slack_notifications_allowed: true,
      telegram_notifications_allowed: true
    )

    user = insert(:user)
    {:ok, user: user, meeting: insert(:meeting, organizer_user_id: user.id)}
  end

  for {factory, worker, id_key} <- @channels do
    describe "dispatch/2 on the #{factory} channel" do
      test "schedules a delivery for a subscribed integration from an event atom",
           %{user: user, meeting: meeting} do
        integration = insert(unquote(factory), user: user, events: ["meeting.created"])

        assert :ok = ChannelFanout.dispatch(:meeting_created, meeting)

        assert_enqueued(
          worker: unquote(worker),
          args: %{
            unquote(id_key) => integration.id,
            "event_type" => "meeting.created",
            "meeting_id" => meeting.id
          }
        )
      end

      test "accepts the wire name as well as the atom", %{user: user, meeting: meeting} do
        insert(unquote(factory), user: user, events: ["meeting.cancelled"])

        assert :ok = ChannelFanout.dispatch("meeting.cancelled", meeting)

        assert_enqueued(worker: unquote(worker), args: %{"event_type" => "meeting.cancelled"})
      end

      test "skips integrations not subscribed to the event, inactive, or another user's",
           %{user: user, meeting: meeting} do
        insert(unquote(factory), user: user, events: ["meeting.cancelled"])
        insert(unquote(factory), user: user, events: ["meeting.created"], is_active: false)
        insert(unquote(factory), user: insert(:user), events: ["meeting.created"])

        assert :ok = ChannelFanout.dispatch(:meeting_created, meeting)

        assert all_enqueued(worker: unquote(worker)) == []
      end
    end
  end

  describe "dispatch/2 with every channel subscribed" do
    setup %{user: user} do
      for {factory, _worker, _key} <- @channels do
        insert(factory, user: user, events: ["meeting.created"])
      end

      :ok
    end

    test "reaches all three channels from one event", %{meeting: meeting} do
      assert :ok = ChannelFanout.dispatch(:meeting_created, meeting)

      for {_factory, worker, _key} <- @channels do
        assert [_job] = all_enqueued(worker: worker)
      end
    end

    test "schedules nothing on any channel when automations are not on the plan",
         %{meeting: meeting} do
      with_config(:tymeslot, :feature_access_checker, ProcessAccessChecker)
      ProcessAccessChecker.answer({:error, :insufficient_plan})

      assert {:error, :insufficient_plan} = ChannelFanout.dispatch(:meeting_created, meeting)

      assert all_enqueued() == []
    end

    test "schedules nothing when the access check itself fails", %{meeting: meeting} do
      with_config(:tymeslot, :feature_access_checker, ProcessAccessChecker)
      ProcessAccessChecker.answer({:error, :checker_unavailable})

      assert {:error, :feature_access_checker_failed} =
               ChannelFanout.dispatch(:meeting_created, meeting)

      assert all_enqueued() == []
    end

    test "checks automations access once per event, not once per channel", %{meeting: meeting} do
      with_config(:tymeslot, :feature_access_checker, __MODULE__.CountsChecks)
      Process.put(:access_checks, 0)

      assert :ok = ChannelFanout.dispatch(:meeting_created, meeting)

      assert Process.get(:access_checks) == 1
    end

    test "a channel switched off for the instance does not stop the others",
         %{meeting: meeting} do
      with_config(:tymeslot, :telegram_notifications_allowed, false)

      assert :ok = ChannelFanout.dispatch(:meeting_created, meeting)

      assert all_enqueued(worker: TelegramWorker) == []
      assert [_job] = all_enqueued(worker: WebhookWorker)
      assert [_job] = all_enqueued(worker: SlackWorker)
    end
  end

  describe "dispatch/3 with a raising channel" do
    test "still reaches the channels after it, and does not raise", %{
      user: user,
      meeting: meeting
    } do
      insert(:slack_integration, user: user, events: ["meeting.created"])

      assert :ok =
               ChannelFanout.dispatch(:meeting_created, meeting,
                 channels: [broken: __MODULE__.RaisingChannel, slack: Slack]
               )

      assert [_job] = all_enqueued(worker: SlackWorker)
    end
  end

  describe "dispatch/2 guards" do
    test "refuses a meeting without an organiser" do
      meeting = insert(:meeting, organizer_user_id: nil)

      assert {:error, :no_organizer} = ChannelFanout.dispatch(:meeting_created, meeting)
      assert all_enqueued() == []
    end

    test "refuses something that is not a meeting row without raising" do
      assert {:error, :not_a_meeting} = ChannelFanout.dispatch(:meeting_created, %{id: 1})
    end

    test "reports an unknown event atom instead of raising", %{user: user, meeting: meeting} do
      insert(:webhook, user: user, events: ["meeting.created"])

      assert {:error, {:dispatch_failed, %ArgumentError{}}} =
               ChannelFanout.dispatch(:meeting_teleported, meeting)

      assert all_enqueued() == []
    end
  end

  describe "dispatch/3 logging" do
    test "does not log a routine skip as a scheduling failure",
         %{user: user, meeting: meeting} do
      # A webhook at the failure threshold but not yet marked disabled is
      # listed for the event but skipped: `:integration_not_active`.
      webhook =
        insert(:webhook,
          user: user,
          events: ["meeting.created"],
          failure_count: WebhookSchema.max_failure_count()
        )

      assert [{webhook.id, {:error, :integration_not_active}}] ==
               Webhooks.schedule_for_event(user.id, "meeting.created", meeting)

      LogCapture.attach()

      assert :ok = ChannelFanout.dispatch(:meeting_created, meeting)

      refute Enum.any?(LogCapture.drain(), fn %{msg: msg} ->
               LogCapture.message_text(msg) =~ "Failed to schedule channel delivery"
             end)
    end

    test "logs a channel's scheduling failure with what failed", %{meeting: meeting} do
      LogCapture.attach()

      assert :ok =
               ChannelFanout.dispatch(:meeting_created, meeting,
                 channels: [failing: __MODULE__.FailingChannel]
               )

      assert %{level: :warning, meta: meta} =
               LogCapture.await_log("Failed to schedule channel delivery")

      assert meta.channel == :failing
      assert meta.integration_id == 4242
      assert meta.event_type == "meeting.created"
      assert meta.reason =~ "boom"
    end
  end

  defmodule RaisingChannel do
    @moduledoc false
    @behaviour Tymeslot.Notifications.Channel

    @impl Tymeslot.Notifications.Channel
    def schedule_for_event(_user_id, _event_type, _meeting), do: raise("scheduling failed")
  end

  defmodule FailingChannel do
    @moduledoc false
    @behaviour Tymeslot.Notifications.Channel

    @impl Tymeslot.Notifications.Channel
    def schedule_for_event(_user_id, _event_type, _meeting), do: [{4242, {:error, :boom}}]
  end

  defmodule CountsChecks do
    @moduledoc false
    @spec check_access(integer(), atom()) :: :ok
    def check_access(_user_id, :automations_allowed) do
      Process.put(:access_checks, Process.get(:access_checks, 0) + 1)
      :ok
    end
  end
end
