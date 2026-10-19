defmodule Tymeslot.Notifications.EventsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :notifications

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias ErrorTracker.Error
  alias Oban.Job
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker}

  @doc false
  @spec forward_occurrence([atom()], map(), map(), pid()) :: :ok
  def forward_occurrence(_event, _measurements, _metadata, test_pid) do
    send(test_pid, :occurrence_recorded)
    :ok
  end

  setup :verify_on_exit!

  # Stands in for an email pipeline that raises rather than returning
  # `{:error, _}` — the shape a template mismatch takes.
  defmodule RaisingWorker do
    @spec schedule_confirmation_emails(term()) :: no_return()
    def schedule_confirmation_emails(_meeting_id), do: raise("email pipeline down")

    @spec schedule_cancellation_emails(term()) :: no_return()
    def schedule_cancellation_emails(_meeting_id), do: raise("email pipeline down")

    @spec schedule_seat_confirmation_emails(term(), term()) :: no_return()
    def schedule_seat_confirmation_emails(_meeting_id, _participant_id),
      do: raise("email pipeline down")

    @spec schedule_reschedule_emails(term(), term()) :: no_return()
    def schedule_reschedule_emails(_meeting, _original), do: raise("email pipeline down")

    @spec cancel_reminder_emails(term()) :: :ok
    def cancel_reminder_emails(_meeting_id), do: :ok

    @spec schedule_reminder_emails(term(), term(), term(), term()) :: :ok
    def schedule_reminder_emails(_meeting_id, _value, _unit, _schedule_at), do: :ok
  end

  # Stands in for an email step whose database write fails.
  defmodule DatabaseDownWorker do
    @spec schedule_confirmation_emails(term()) :: no_return()
    def schedule_confirmation_emails(_meeting_id),
      do: raise(DBConnection.ConnectionError, "connection refused")

    @spec schedule_seat_confirmation_emails(term(), term()) :: no_return()
    def schedule_seat_confirmation_emails(_meeting_id, _participant_id),
      do: raise(DBConnection.ConnectionError, "connection refused")

    @spec cancel_reminder_emails(term()) :: :ok
    def cancel_reminder_emails(_meeting_id), do: :ok

    @spec schedule_reminder_emails(term(), term(), term(), term()) :: :ok
    def schedule_reminder_emails(_meeting_id, _value, _unit, _schedule_at), do: :ok
  end

  describe "dispatch wiring" do
    setup do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        slack_notifications_allowed: true,
        telegram_notifications_allowed: true,
        environment: :test
      )

      # Allow Orchestrator's immediate email side-effects to no-op so we can
      # focus on the dispatch wiring rather than the email pipeline.
      stub(Tymeslot.EmailServiceMock, :send_appointment_confirmations, fn _details ->
        {:ok, %{}}
      end)

      user = insert(:user)

      slack_integration =
        insert(:slack_integration,
          user: user,
          events: ["meeting.created", "meeting.cancelled", "meeting.rescheduled"],
          is_active: true
        )

      telegram_integration =
        insert(:telegram_integration,
          user: user,
          events: ["meeting.created", "meeting.cancelled", "meeting.rescheduled"],
          is_active: true
        )

      meeting = insert(:meeting, organizer_user_id: user.id)

      %{
        user: user,
        meeting: meeting,
        slack_integration: slack_integration,
        telegram_integration: telegram_integration
      }
    end

    test "meeting_created/1 enqueues Telegram and Slack jobs", %{
      meeting: meeting,
      slack_integration: slack_integration,
      telegram_integration: telegram_integration
    } do
      Events.meeting_created(meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        }
      )

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => slack_integration.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        }
      )
    end

    test "meeting_cancelled/1 enqueues Telegram and Slack jobs", %{
      meeting: meeting,
      slack_integration: slack_integration,
      telegram_integration: telegram_integration
    } do
      Events.meeting_cancelled(meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.cancelled",
          "meeting_id" => meeting.id
        }
      )

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => slack_integration.id,
          "event_type" => "meeting.cancelled",
          "meeting_id" => meeting.id
        }
      )
    end

    test "meeting_rescheduled/2 enqueues Telegram and Slack jobs", %{
      meeting: meeting,
      slack_integration: slack_integration,
      telegram_integration: telegram_integration
    } do
      Events.meeting_rescheduled(meeting, meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.rescheduled",
          "meeting_id" => meeting.id
        }
      )

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => slack_integration.id,
          "event_type" => "meeting.rescheduled",
          "meeting_id" => meeting.id
        }
      )
    end

    # A booking with a video room defers this event to `VideoRoomWorker`, which
    # announces without a link once recovery gives up on the room and announces
    # again if a late attempt finally creates one. Both reach here, so this is
    # where the second one has to stop.
    test "meeting_created/1 announces a meeting once, however often it is called", %{
      meeting: meeting,
      slack_integration: slack_integration,
      telegram_integration: telegram_integration
    } do
      assert {:ok, _first} = Events.meeting_created(meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        }
      )

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => slack_integration.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        }
      )

      # Every channel here dedupes on a five-minute Oban uniqueness window, so
      # back-to-back calls in a test would look identical whether the event was
      # claimed or not. Clearing the queue models the gap this actually has to
      # survive: a recovering video room job announces the booking, then reaches
      # its room hours later, long after those windows expired.
      Repo.delete_all(Job)

      assert {:ok, :already_announced} = Events.meeting_created(meeting)

      refute_enqueued(worker: TelegramWorker)
      refute_enqueued(worker: SlackWorker)
    end

    test "meeting_created/1 stamps the meeting with the moment it was announced", %{
      meeting: meeting
    } do
      assert is_nil(meeting.announced_at)

      assert {:ok, _result} = Events.meeting_created(meeting)

      assert {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert %DateTime{} = reloaded.announced_at
    end

    test "meeting_created/1 also records the announcement where a re-gate cannot clear it", %{
      meeting: meeting
    } do
      # `announced_at` is the once-only claim, and a reschedule that sends a
      # confirmed booking back for approval clears it so the second approval
      # can claim the fan-out again. `first_announced_at` is the permanent
      # counterpart, and is the fact the refund rule reads when such a request
      # is later declined.
      assert is_nil(meeting.first_announced_at)

      assert {:ok, _result} = Events.meeting_created(meeting)
      assert {:ok, announced} = MeetingQueries.get_meeting(meeting.id)
      assert announced.first_announced_at == announced.announced_at

      # Free the claim, as the re-gating reschedule does, and announce again.
      # The first stamp must not move.
      {1, _rows} =
        Repo.update_all(
          from(m in MeetingSchema, where: m.id == ^meeting.id),
          set: [announced_at: nil]
        )

      assert {:ok, reloaded} = MeetingQueries.get_meeting(meeting.id)
      assert {:ok, _again} = Events.meeting_created(reloaded)
      assert {:ok, reannounced} = MeetingQueries.get_meeting(meeting.id)

      assert reannounced.first_announced_at == announced.first_announced_at
      assert %DateTime{} = reannounced.announced_at
    end

    # A reschedule that sends a confirmed booking back for approval frees the
    # claim so the host's second approval still reaches the invitee's emails
    # and reminders. Integrations already heard `meeting.created` for this
    # booking; telling them again would read as a second booking.
    test "meeting_created/1 tells the channels a re-gated booking moved rather than was made", %{
      meeting: meeting,
      slack_integration: slack_integration,
      telegram_integration: telegram_integration
    } do
      assert {:ok, _first} = Events.meeting_created(meeting)

      # The first announcement's jobs would otherwise dedupe the second
      # through the five-minute uniqueness window; see the test above.
      Repo.delete_all(Job)

      {1, _rows} =
        Repo.update_all(
          from(m in MeetingSchema, where: m.id == ^meeting.id),
          set: [announced_at: nil]
        )

      # The struct still says the meeting was never announced. The claim reads
      # the row, so a caller holding a stale struct cannot mislabel it.
      assert is_nil(meeting.first_announced_at)
      assert {:ok, _again} = Events.meeting_created(meeting)

      for {worker, integration} <- [
            {TelegramWorker, telegram_integration},
            {SlackWorker, slack_integration}
          ] do
        assert_enqueued(
          worker: worker,
          args: %{
            "integration_id" => integration.id,
            "event_type" => "meeting.rescheduled",
            "meeting_id" => meeting.id
          }
        )

        refute_enqueued(worker: worker, args: %{"event_type" => "meeting.created"})
      end
    end
  end

  # Issue #76: the email step can raise instead of returning `{:error, _}`
  # (it used to render templates in-process, where a payload they did not fit
  # raised). That
  # exception used to escape before the webhook, Telegram and Slack dispatches
  # sequenced after it, silently costing a reschedule every downstream channel.
  describe "a raising email step" do
    setup do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        slack_notifications_allowed: true,
        telegram_notifications_allowed: true,
        environment: :test
      )

      original_worker = Application.get_env(:tymeslot, :email_worker_module)
      Application.put_env(:tymeslot, :email_worker_module, RaisingWorker)

      on_exit(fn ->
        case original_worker do
          nil -> Application.delete_env(:tymeslot, :email_worker_module)
          worker -> Application.put_env(:tymeslot, :email_worker_module, worker)
        end
      end)

      user = insert(:user)

      telegram_integration =
        insert(:telegram_integration,
          user: user,
          events: ["meeting.created", "meeting.cancelled", "meeting.rescheduled"],
          is_active: true
        )

      meeting = insert(:meeting, organizer_user_id: user.id, status: "confirmed")

      %{meeting: meeting, telegram_integration: telegram_integration}
    end

    test "meeting_rescheduled/2 still dispatches Telegram and reports the failure", %{
      meeting: meeting,
      telegram_integration: telegram_integration
    } do
      assert {:error, {:notifications_failed, %RuntimeError{}}} =
               Events.meeting_rescheduled(meeting, meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.rescheduled",
          "meeting_id" => meeting.id
        }
      )
    end

    # A fault composing the emails fails the same way on every retry, so the
    # booking is announced without them rather than refused for good.
    test "meeting_created/1 announces a booking whose emails could not be composed", %{
      meeting: meeting,
      telegram_integration: telegram_integration
    } do
      assert {:ok, :not_sendable} = Events.meeting_created(meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{"integration_id" => telegram_integration.id, "event_type" => "meeting.created"}
      )

      assert %{announced_at: %DateTime{}} = Repo.reload!(meeting)
    end

    # The booking's emails and its announcement commit together, and the
    # integrations hear of it only once they have: a database that fails the
    # email step leaves the claim free for the caller's retry.
    test "meeting_created/1 tells no integration when the database fails its emails, and leaves the claim for a retry",
         %{meeting: meeting} do
      Application.put_env(:tymeslot, :email_worker_module, DatabaseDownWorker)

      assert {:error, {:notifications_failed, %DBConnection.ConnectionError{}}} =
               Events.meeting_created(meeting)

      refute_enqueued(worker: TelegramWorker)
      assert %{announced_at: nil} = Repo.reload!(meeting)
    end

    # A group seat follows the solo rule: a fault composing its confirmation
    # books the seat without it; only a storage failure refuses the seat.
    test "seat_booked_deferred/3 books a seat whose confirmation could not be composed", %{
      meeting: meeting
    } do
      assert {{:ok, :not_sendable}, [_fan_out]} =
               Events.seat_booked_deferred(meeting, %{id: 1})
    end

    test "seat_booked_deferred/3 refuses a seat when the database fails its confirmation", %{
      meeting: meeting
    } do
      Application.put_env(:tymeslot, :email_worker_module, DatabaseDownWorker)

      assert {{:error, {:notifications_failed, %DBConnection.ConnectionError{}}}, _pending} =
               Events.seat_booked_deferred(meeting, %{id: 1})
    end

    test "meeting_cancelled/1 still dispatches Telegram and reports the failure", %{
      meeting: meeting,
      telegram_integration: telegram_integration
    } do
      assert {:error, {:notifications_failed, %RuntimeError{}}} =
               Events.meeting_cancelled(meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.cancelled",
          "meeting_id" => meeting.id
        }
      )
    end

    # The email step runs inside the announcement's transaction, so the report
    # is written from a task of its own, whatever becomes of the transaction.
    test "meeting_created/1 records the email failure with the meeting", %{meeting: meeting} do
      with_config(:error_tracker, enabled: true)
      test_pid = self()
      handler = "events-test-occurrence-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:error_tracker, :occurrence, :new],
          &__MODULE__.forward_occurrence/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, :not_sendable} = Events.meeting_created(meeting)
      assert_receive :occurrence_recorded, 5_000

      assert [%Error{kind: "Elixir.RuntimeError", reason: "email pipeline down"} = error] =
               Error |> Repo.all() |> Repo.preload(:occurrences)

      assert [%{context: %{"event" => "meeting_created", "meeting_id" => meeting_id}}] =
               error.occurrences

      assert meeting_id == meeting.id
    end
  end
end
