defmodule Tymeslot.OnboardingTest do
  use Tymeslot.DataCase, async: true

  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :utils
  @moduletag :onboarding

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Availability.Schedules
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Onboarding
  alias Tymeslot.Workers.EmailWorker

  describe "get_or_create_profile/1" do
    test "creates a profile when none exists" do
      user = insert(:user)
      assert {:ok, profile} = Onboarding.get_or_create_profile(user.id)
      assert profile.user_id == user.id
    end

    test "the new profile comes with a default schedule and its seven weekdays" do
      user = insert(:user)
      {:ok, profile} = Onboarding.get_or_create_profile(user.id)

      assert %{is_default: true} = schedule = Schedules.get_default(profile.id)
      assert length(WeeklySchedule.get_weekly_schedule(schedule.id)) == 7
    end

    test "returns existing profile when one already exists" do
      user = insert(:user)
      {:ok, original_profile} = Onboarding.get_or_create_profile(user.id)
      {:ok, same_profile} = Onboarding.get_or_create_profile(user.id)
      assert same_profile.id == original_profile.id
    end
  end

  describe "email_booking_link/1" do
    test "enqueues one job per ten minutes" do
      user = insert(:user)

      assert :ok = Onboarding.email_booking_link(user)
      assert :ok = Onboarding.email_booking_link(user)

      assert [job] = all_enqueued(worker: EmailWorker)
      assert job.args == %{"action" => "send_booking_link_email", "user_id" => user.id}
    end
  end

  describe "keep_booking_link/3" do
    test "completes onboarding and stamps the first share" do
      user = insert(:user, onboarding_completed_at: nil)
      profile = insert(:profile, user: user, booking_link_first_shared_at: nil)

      assert {:ok, %{onboarding_completed_at: %DateTime{}}} =
               Onboarding.keep_booking_link(user, profile, "copy")

      assert %DateTime{} = Repo.reload!(profile).booking_link_first_shared_at
      refute_enqueued(worker: EmailWorker)
    end

    test "email_me queues the email first" do
      user = insert(:user, onboarding_completed_at: nil)
      profile = insert(:profile, user: user)

      assert {:ok, _user} = Onboarding.keep_booking_link(user, profile, "email_me")
      assert_enqueued(worker: EmailWorker, args: %{"user_id" => user.id})
    end

    test "refuses a method outside the keep list, changing nothing" do
      user = insert(:user, onboarding_completed_at: nil)
      profile = insert(:profile, user: user, booking_link_first_shared_at: nil)

      assert {:error, :unknown_method} = Onboarding.keep_booking_link(user, profile, "fax")
      assert Repo.reload!(user).onboarding_completed_at == nil
      assert Repo.reload!(profile).booking_link_first_shared_at == nil
    end

    test "only the keep that completes onboarding is counted" do
      attach_own_telemetry([
        [:tymeslot, :onboarding, :link_kept],
        [:tymeslot, :onboarding, :completed]
      ])

      user = insert(:user, onboarding_completed_at: nil)
      profile = insert(:profile, user: user)

      assert {:ok, completed} = Onboarding.keep_booking_link(user, profile, "copy")

      assert {:ok, _again} =
               Onboarding.keep_booking_link(completed, Repo.reload!(profile), "phone")

      assert_received {:telemetry, [:tymeslot, :onboarding, :link_kept], %{method: "copy"}}
      assert_received {:telemetry, [:tymeslot, :onboarding, :completed], _}
      refute_received {:telemetry, [:tymeslot, :onboarding, :link_kept], _}
      refute_received {:telemetry, [:tymeslot, :onboarding, :completed], _}
    end
  end

  describe "subscribe/1 and broadcast_preview_opened/1" do
    test "a subscriber hears its own user's opening, and no one else's" do
      :ok = Onboarding.subscribe(42)

      assert :ok = Onboarding.broadcast_preview_opened(43)
      refute_receive {:onboarding, :preview_opened}, 50

      assert :ok = Onboarding.broadcast_preview_opened(42)
      assert_receive {:onboarding, :preview_opened}
    end
  end

  describe "complete_onboarding/1" do
    test "marks user onboarding as complete" do
      user = insert(:user, onboarding_completed_at: nil)
      assert {:ok, updated_user} = Onboarding.complete_onboarding(user)
      assert %DateTime{} = updated_user.onboarding_completed_at
    end

    test "is idempotent for already-completed users" do
      user = insert(:user, onboarding_completed_at: nil)
      {:ok, completed_user} = Onboarding.complete_onboarding(user)
      {:ok, re_completed_user} = Onboarding.complete_onboarding(completed_user)

      assert re_completed_user.onboarding_completed_at ==
               completed_user.onboarding_completed_at
    end

    test "keeps an earlier completion time, even when called with a stale struct" do
      completed_at = ~U[2026-01-15 09:30:00Z]
      user = insert(:user, onboarding_completed_at: completed_at)

      # A concurrent caller that loaded the user before the first completion.
      stale = %{user | onboarding_completed_at: nil}

      assert {:ok, %{onboarding_completed_at: ^completed_at}} =
               Onboarding.complete_onboarding(stale)

      assert Repo.get!(UserSchema, user.id).onboarding_completed_at == completed_at
    end

    test "returns not found for a user that no longer exists" do
      user = insert(:user, onboarding_completed_at: nil)
      Repo.delete!(user)

      assert {:error, :not_found} = Onboarding.mark_onboarding_complete(user)
    end
  end

  describe "complete_onboarding/1 telemetry" do
    test "emits [:tymeslot, :onboarding, :completed] telemetry for a real user" do
      user = insert(:user, onboarding_completed_at: nil)
      test_pid = self()

      :telemetry.attach(
        "test-onboarding-completed",
        [:tymeslot, :onboarding, :completed],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test-onboarding-completed") end)

      assert {:ok, _updated} = Onboarding.complete_onboarding(user)
      assert_received {:telemetry, %{count: 1}, %{}}
    end

    test "emits nothing for a user who has already completed onboarding" do
      attach_own_telemetry([[:tymeslot, :onboarding, :completed]])
      user = insert(:user, onboarding_completed_at: ~U[2026-01-15 09:30:00Z])

      assert {:ok, _user} = Onboarding.complete_onboarding(user)
      refute_received {:telemetry, [:tymeslot, :onboarding, :completed], _}
    end
  end

  # Forwards only events this test's own process emits, so concurrent async
  # tests completing their own users cannot satisfy or break an assertion.
  defp attach_own_telemetry(events) do
    test_pid = self()
    id = make_ref()

    :telemetry.attach_many(
      id,
      events,
      fn event, _measurements, metadata, _config ->
        if self() == test_pid, do: send(test_pid, {:telemetry, event, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  describe "dashboard tour helpers" do
    test "dashboard_tour_seen?/1 returns false for a user with no timestamp" do
      user = insert(:user, dashboard_tour_seen_at: nil)
      refute Onboarding.dashboard_tour_seen?(user)
    end

    test "dashboard_tour_seen?/1 returns true for a user with a timestamp" do
      user = insert(:user, dashboard_tour_seen_at: DateTime.utc_now(:second))
      assert Onboarding.dashboard_tour_seen?(user)
    end

    test "mark_dashboard_tour_seen/1 sets the timestamp when nil" do
      user = insert(:user, dashboard_tour_seen_at: nil)

      assert {:ok, updated} = Onboarding.mark_dashboard_tour_seen(user)
      assert %DateTime{} = updated.dashboard_tour_seen_at
    end

    test "mark_dashboard_tour_seen/1 is idempotent — second call does not overwrite the first timestamp" do
      user = insert(:user, dashboard_tour_seen_at: nil)

      {:ok, first} = Onboarding.mark_dashboard_tour_seen(user)
      {:ok, second} = Onboarding.mark_dashboard_tour_seen(first)

      assert second.dashboard_tour_seen_at == first.dashboard_tour_seen_at
    end
  end

  describe "dashboard setup widget helpers" do
    test "toggle_dashboard_setup_item/2 ticks an item and reflects in the predicate" do
      user = insert(:user)
      refute "avatar" in (user.dashboard_setup_done_items || [])

      {:ok, updated} = Onboarding.toggle_dashboard_setup_item(user, "avatar")

      assert "avatar" in (updated.dashboard_setup_done_items || [])
      assert "avatar" in updated.dashboard_setup_done_items
    end

    test "toggle_dashboard_setup_item/2 un-ticks an already-done item" do
      user = insert(:user, dashboard_setup_done_items: ["avatar"])

      {:ok, updated} = Onboarding.toggle_dashboard_setup_item(user, "avatar")

      refute "avatar" in (updated.dashboard_setup_done_items || [])
      assert updated.dashboard_setup_done_items == []
    end

    test "toggle_dashboard_setup_item/2 refuses items that are not ticked by hand" do
      user = insert(:user, dashboard_setup_done_items: ["avatar"])

      # Calendar and video complete only from a real connection; the items an
      # earlier checklist offered (the wizard now does them) and anything else
      # are not items at all.
      for key <- ["calendar", "video", "theme", "meeting_types", "share", "bogus"] do
        assert {:error, :unknown_item} = Onboarding.toggle_dashboard_setup_item(user, key)
      end

      assert Repo.get!(UserSchema, user.id).dashboard_setup_done_items == ["avatar"]
    end

    test "manual_dashboard_setup_items/0 lists the items a host may tick by hand" do
      for key <- Onboarding.manual_dashboard_setup_items() do
        user = insert(:user)

        assert {:ok, %{dashboard_setup_done_items: [^key]}} =
                 Onboarding.toggle_dashboard_setup_item(user, key)
      end
    end

    test "toggle_dashboard_setup_item/2 keeps a tick made from another tab" do
      user = insert(:user)
      stale = user

      {:ok, _ticked_in_first_tab} = Onboarding.toggle_dashboard_setup_item(user, "avatar")
      {:ok, updated} = Onboarding.toggle_dashboard_setup_item(stale, "embed")

      assert Enum.sort(updated.dashboard_setup_done_items) == ["avatar", "embed"]

      assert Enum.sort(Repo.get!(UserSchema, user.id).dashboard_setup_done_items) ==
               ["avatar", "embed"]
    end

    test "dismiss_dashboard_setup/1 stamps the timestamp and is idempotent" do
      user = insert(:user, dashboard_setup_dismissed_at: nil)
      refute Onboarding.dashboard_setup_dismissed?(user)

      {:ok, first} = Onboarding.dismiss_dashboard_setup(user)
      assert Onboarding.dashboard_setup_dismissed?(first)

      {:ok, second} = Onboarding.dismiss_dashboard_setup(first)
      assert second.dashboard_setup_dismissed_at == first.dashboard_setup_dismissed_at
    end
  end
end
