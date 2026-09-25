defmodule Tymeslot.Integrations.HealthCheck.AlertingTest do
  # async: false: `capture_admin_alerts` and the threshold overrides swap
  # global application config.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :workers

  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Test.ClockHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers, only: [insert_unhealthy_health_row: 4]

  alias Tymeslot.Bookings.CalendarCheck
  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes
  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.HealthCheck.Alerting
  alias Tymeslot.Integrations.HealthCheck.AvailabilityRefusalSchema
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.DataRetentionWorker
  alias Tymeslot.Workers.IntegrationAutoPauseWorker
  alias Tymeslot.Workers.IntegrationHealthAlertWorker

  setup :verify_on_exit!
  setup :capture_admin_alerts

  setup do
    setup_config(:tymeslot, :integration_health_alerting,
      window_hours: 1,
      refusals_per_user: 5,
      affected_users_threshold: 1,
      reauth_flags_threshold: 3,
      auto_pause_threshold: 1
    )

    %{user: insert(:user), hour: ~U[2026-09-23 10:00:00Z]}
  end

  describe "availability refusals, from booking submit to alert" do
    test "a booker refused because the organiser's calendars are unreadable is counted, and the hourly run alerts",
         %{user: user} do
      TestMocks.setup_calendar_mocks(result: {:error, :all_calendars_unavailable})
      start = DateTime.add(DateTime.utc_now(), 2, :day)

      slot = %{
        start_datetime: start,
        end_datetime: DateTime.add(start, 30, :minute),
        organizer_user_id: user.id
      }

      for _attempt <- 1..5 do
        assert {:error, :availability_unverifiable} = CalendarCheck.enforce(slot, %{})
      end

      assert [%{refusals: 5, bucket_start: bucket}] = Repo.all(AvailabilityRefusalSchema)

      freeze_clock(DateTime.add(bucket, 65, :minute))
      assert :ok = perform_job(IntegrationHealthAlertWorker, %{})

      assert_received {:send_alert, :integration_health_failure,
                       %{signal: "availability_refusals"} = payload}

      assert payload.count == 1
      assert payload.affected_user_ids == [user.id]
      assert payload.refusals == 5
      assert payload.summary =~ "1 organiser(s) served no availability"
    end
  end

  describe "track_availability/2" do
    test "records only the unreadable-calendar refusals and passes every result through",
         %{user: user} do
      assert {:error, :some_calendars_unavailable} =
               Alerting.track_availability({:error, :some_calendars_unavailable}, user.id)

      assert {:ok, []} = Alerting.track_availability({:ok, []}, user.id)
      assert {:error, :timeout} = Alerting.track_availability({:error, :timeout}, user.id)

      assert [%{user_id: user_id, refusals: 1}] = Repo.all(AvailabilityRefusalSchema)
      assert user_id == user.id
    end

    test "a refusal for a user that no longer exists is dropped, not raised" do
      assert {:error, :all_calendars_unavailable} =
               Alerting.track_availability({:error, :all_calendars_unavailable}, 999_999_999)

      assert Repo.all(AvailabilityRefusalSchema) == []
    end
  end

  describe "availability refusal signal" do
    test "alerts once an organiser reaches the per-user refusal threshold", %{
      user: user,
      hour: hour
    } do
      insert_refusals(user, hour, 5)

      assert :alerted = Alerting.check_signal(:availability_refusals, at(hour, 1))
      assert_received {:send_alert, :integration_health_failure, %{count: 1}}
    end

    test "stays quiet below the per-user refusal threshold", %{user: user, hour: hour} do
      insert_refusals(user, hour, 4)

      assert :ok = Alerting.check_signal(:availability_refusals, at(hour, 1))
      refute_received {:send_alert, _type, _payload}
    end

    test "ignores refusals outside the window", %{user: user, hour: hour} do
      # Two hours back: outside both the window and the previous evaluation's.
      insert_refusals(user, DateTime.add(hour, -2, :hour), 50)
      insert_refusals(user, DateTime.add(hour, 1, :hour), 50)

      assert :ok = Alerting.check_signal(:availability_refusals, at(hour, 1))
      refute_received {:send_alert, _type, _payload}
    end
  end

  describe "reauth flag signal" do
    test "alerts at the threshold of new flags, broken down by provider", %{
      user: user,
      hour: hour
    } do
      flag_integrations(user, 3, at(hour, 0))

      assert :alerted = Alerting.check_signal(:reauth_flags, at(hour, 1))

      assert_received {:send_alert, :integration_health_failure,
                       %{signal: "reauth_flags"} = payload}

      assert payload.count == 3
      assert payload.by_provider == %{"caldav" => 3}
    end

    test "stays quiet below the threshold", %{user: user, hour: hour} do
      flag_integrations(user, 2, at(hour, 0))

      assert :ok = Alerting.check_signal(:reauth_flags, at(hour, 1))
      refute_received {:send_alert, _type, _payload}
    end

    test "re-flagging an integration already awaiting reconnection is not a new flag", %{
      user: user,
      hour: hour
    } do
      [integration] = flag_integrations(user, 1, at(hour, 0))

      freeze_clock(at(hour, 1))
      {:ok, reflagged} = CalendarIntegrationQueries.mark_needs_reauth(integration, "again")

      assert reflagged.reauth_flagged_at == integration.reauth_flagged_at
    end

    test "a flag cleared within the window still counts", %{user: user, hour: hour} do
      integrations = flag_integrations(user, 3, at(hour, 0))
      Enum.each(integrations, &CalendarIntegrationQueries.clear_reauth_flag/1)

      assert :alerted = Alerting.check_signal(:reauth_flags, at(hour, 1))
    end
  end

  describe "deduplication" do
    test "the dedup key is stable across runs with different counts in one band", %{
      user: user,
      hour: hour
    } do
      flag_integrations(user, 3, at(hour, 0))
      next_hour = DateTime.add(hour, 1, :hour)
      flag_integrations(user, 5, at(next_hour, 0))

      assert :alerted = Alerting.check_signal(:reauth_flags, at(hour, 1))
      assert :alerted = Alerting.check_signal(:reauth_flags, at(next_hour, 1))

      assert_received {:send_alert, :integration_health_failure, %{count: 3} = first}
      assert_received {:send_alert, :integration_health_failure, %{count: 5} = second}

      refute first.summary == second.summary

      assert AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(first)) ==
               AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(second))
    end

    test "crossing into the severe band produces a new dedup key", %{user: user, hour: hour} do
      flag_integrations(user, 3, at(hour, 0))
      next_hour = DateTime.add(hour, 1, :hour)
      flag_integrations(user, 30, at(next_hour, 0))

      Alerting.check_signal(:reauth_flags, at(hour, 1))
      Alerting.check_signal(:reauth_flags, at(next_hour, 1))

      assert_received {:send_alert, :integration_health_failure, %{band: "elevated"} = elevated}
      assert_received {:send_alert, :integration_health_failure, %{band: "severe"} = severe}

      refute AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(elevated)) ==
               AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(severe))
    end
  end

  describe "deduplication across incidents" do
    test "a second incident after a recovery alerts and recovers under new keys", %{
      user: user,
      hour: hour
    } do
      insert_refusals(user, hour, 5)
      later = DateTime.add(hour, 3, :hour)
      insert_refusals(user, later, 5)

      assert :alerted = Alerting.check_signal(:availability_refusals, at(hour, 1))
      assert :recovered = Alerting.check_signal(:availability_refusals, at(hour, 2))
      assert :alerted = Alerting.check_signal(:availability_refusals, at(later, 1))
      assert :recovered = Alerting.check_signal(:availability_refusals, at(later, 2))

      assert_received {:send_alert, :integration_health_failure, first_failure}
      assert_received {:send_alert, :integration_health_recovery, first_recovery}
      assert_received {:send_alert, :integration_health_failure, second_failure}
      assert_received {:send_alert, :integration_health_recovery, second_recovery}

      refute AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(first_failure)) ==
               AlertTypes.dedup_key(
                 :integration_health_failure,
                 PIIScrubber.scrub(second_failure)
               )

      refute AlertTypes.dedup_key(:integration_health_recovery, PIIScrubber.scrub(first_recovery)) ==
               AlertTypes.dedup_key(
                 :integration_health_recovery,
                 PIIScrubber.scrub(second_recovery)
               )

      assert AlertTypes.dedup_key(:integration_health_recovery, PIIScrubber.scrub(first_recovery)) ==
               "integration_health_recovery:availability_refusals:" <>
                 DateTime.to_iso8601(DateTime.add(hour, 1, :hour))
    end

    test "each hour of one incident shares the key of its first alert", %{
      user: user,
      hour: hour
    } do
      for offset <- 0..2, do: insert_refusals(user, DateTime.add(hour, offset, :hour), 5)

      for offset <- 1..3, do: Alerting.check_signal(:availability_refusals, at(hour, offset))

      keys =
        for _n <- 1..3 do
          assert_received {:send_alert, :integration_health_failure, payload}
          AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(payload))
        end

      assert [_one_key] = Enum.uniq(keys)
    end

    test "an incident longer than the dedup window keeps one key rather than one per hour", %{
      user: user,
      hour: hour
    } do
      for offset <- 0..26, do: insert_refusals(user, DateTime.add(hour, offset, :hour), 5)

      Alerting.check_signal(:availability_refusals, at(hour, 26))
      Alerting.check_signal(:availability_refusals, at(hour, 27))

      assert_received {:send_alert, :integration_health_failure, earlier}
      assert_received {:send_alert, :integration_health_failure, later}

      assert AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(earlier)) ==
               "integration_health_failure:availability_refusals:elevated"

      assert AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(earlier)) ==
               AlertTypes.dedup_key(:integration_health_failure, PIIScrubber.scrub(later))
    end
  end

  describe "recovery" do
    test "fires once when a signal drops back under its threshold", %{user: user, hour: hour} do
      insert_refusals(user, hour, 5)

      assert :alerted = Alerting.check_signal(:availability_refusals, at(hour, 1))
      assert_received {:send_alert, :integration_health_failure, _payload}

      assert :recovered = Alerting.check_signal(:availability_refusals, at(hour, 2))

      assert_received {:send_alert, :integration_health_recovery,
                       %{signal: "availability_refusals", count: 0} = recovery}

      assert recovery.summary =~ "back under threshold"

      assert :ok = Alerting.check_signal(:availability_refusals, at(hour, 3))
      refute_received {:send_alert, _type, _payload}
    end

    test "does not fire when the signal was never above its threshold", %{
      user: user,
      hour: hour
    } do
      insert_refusals(user, hour, 4)

      assert :ok = Alerting.check_signal(:availability_refusals, at(hour, 2))
      refute_received {:send_alert, _type, _payload}
    end
  end

  describe "IntegrationHealthAlertWorker" do
    test "a signal whose check raises does not stop the others", %{user: user, hour: hour} do
      setup_config(:tymeslot, :integration_health_alerting,
        refusals_per_user: :not_a_number,
        reauth_flags_threshold: 3
      )

      flag_integrations(user, 3, at(hour, 0))
      freeze_clock(at(hour, 1))

      assert :ok = perform_job(IntegrationHealthAlertWorker, %{})
      assert_received {:send_alert, :integration_health_failure, %{signal: "reauth_flags"}}
      refute_received {:send_alert, _type, %{signal: "availability_refusals"}}
    end
  end

  describe "auto-pause" do
    test "one run raises one alert counting every integration it paused", %{user: user} do
      long_ago = DateTime.add(DateTime.utc_now(), -15, :day)
      calendars = for _n <- 1..2, do: insert(:calendar_integration, user: user)
      video = insert(:video_integration, user: user)

      Enum.each(calendars, fn calendar ->
        insert_unhealthy_health_row(user, :calendar, calendar.id, became_unhealthy_at: long_ago)
      end)

      insert_unhealthy_health_row(user, :video, video.id, became_unhealthy_at: long_ago)

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})

      assert_received {:send_alert, :integration_health_failure,
                       %{signal: "auto_pause"} = payload}

      refute_received {:send_alert, _type, _payload}

      assert payload.count == 3
      assert payload.calendar_paused == 2
      assert payload.video_paused == 1

      assert Enum.sort(payload.calendar_integration_ids) ==
               Enum.sort(Enum.map(calendars, & &1.id))

      assert payload.video_integration_ids == [video.id]
      assert payload.run_date == Date.to_iso8601(Date.utc_today())
    end

    test "a run pausing fewer than the threshold raises nothing", %{user: user} do
      setup_config(:tymeslot, :integration_health_alerting, auto_pause_threshold: 2)
      calendar = insert(:calendar_integration, user: user)

      insert_unhealthy_health_row(user, :calendar, calendar.id,
        became_unhealthy_at: DateTime.add(DateTime.utc_now(), -15, :day)
      )

      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})
      refute_received {:send_alert, _type, _payload}
    end

    test "a run that pauses nothing raises nothing" do
      assert :ok = IntegrationAutoPauseWorker.perform(%Oban.Job{})
      refute_received {:send_alert, _type, _payload}
    end
  end

  describe "retention" do
    test "the data retention run prunes refusal counters past their window", %{user: user} do
      now = DateTime.utc_now(:second)
      insert_refusals(user, DateTime.add(now, -31, :day), 1)
      recent = insert_refusals(user, DateTime.add(now, -1, :day), 1)

      assert :ok = perform_job(DataRetentionWorker, %{})

      assert [%{id: id}] = Repo.all(AvailabilityRefusalSchema)
      assert id == recent.id
    end
  end

  defp at(hour, offset_hours),
    do: hour |> DateTime.add(offset_hours, :hour) |> DateTime.add(5, :minute)

  defp insert_refusals(user, bucket_start, refusals) do
    Repo.insert!(%AvailabilityRefusalSchema{
      user_id: user.id,
      bucket_start: bucket_start,
      refusals: refusals
    })
  end

  defp flag_integrations(user, count, flagged_at) do
    freeze_clock(flagged_at)

    integrations =
      for _n <- 1..count do
        {:ok, flagged} =
          :calendar_integration
          |> insert(user: user)
          |> CalendarIntegrationQueries.mark_needs_reauth("Token revoked")

        flagged
      end

    unfreeze_clock()
    integrations
  end
end
