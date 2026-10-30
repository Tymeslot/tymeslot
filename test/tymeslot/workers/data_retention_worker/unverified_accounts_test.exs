defmodule Tymeslot.Workers.DataRetentionWorker.UnverifiedAccountsTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers
  @moduletag :auth

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.DataRetentionWorker
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  defp days_ago(days), do: DateTime.add(DateTime.utc_now(:second), -days, :day)

  describe "perform/1 - unverified account cleanup" do
    test "deletes accounts still unverified 30 days after sign-up, keeps verified and newer ones" do
      stale = insert(:unverified_user, inserted_at: days_ago(31), signup_ip: "203.0.113.9")
      fresh = insert(:unverified_user, inserted_at: days_ago(10))
      verified = insert(:user, inserted_at: days_ago(400))

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(UserSchema, stale.id)
      assert Repo.get(UserSchema, fresh.id)
      assert Repo.get(UserSchema, verified.id)
    end

    test "spares an old account its owner was sent a fresh link for within the window" do
      user =
        insert(:unverified_user,
          inserted_at: days_ago(60),
          verification_sent_at: days_ago(2)
        )

      assert :ok = perform_job(DataRetentionWorker, %{})

      assert Repo.get(UserSchema, user.id)
    end

    test "spares an admin, however long unverified" do
      admin = insert(:unverified_user, is_admin: true, inserted_at: days_ago(400))

      assert :ok = perform_job(DataRetentionWorker, %{})

      assert Repo.get(UserSchema, admin.id)
    end

    test "deletes a social account and one that was used, both locked out until verified" do
      github =
        insert(:unverified_user,
          provider: "github",
          github_user_id: "7001",
          password_hash: nil,
          inserted_at: days_ago(400)
        )

      onboarded =
        insert(:unverified_user,
          inserted_at: days_ago(400),
          last_active_at: days_ago(200),
          onboarding_completed_at: days_ago(399)
        )

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(UserSchema, github.id)
      refute Repo.get(UserSchema, onboarded.id)
    end

    test "spares an account until its meeting still to come is over" do
      host = insert(:unverified_user, inserted_at: days_ago(400))
      starts = DateTime.add(DateTime.utc_now(:second), 2, :day)

      meeting =
        insert(:meeting,
          organizer_user: host,
          organizer_email: host.email,
          status: :confirmed,
          start_time: starts,
          end_time: DateTime.add(starts, 30, :minute)
        )

      assert :ok = perform_job(DataRetentionWorker, %{})
      assert Repo.get(UserSchema, host.id)

      meeting |> Changeset.change(status: :cancelled) |> Repo.update!()

      assert :ok = perform_job(DataRetentionWorker, %{})
      refute Repo.get(UserSchema, host.id)
    end

    test "erases a used account as the deletion job would: third-party grants and queued jobs go too" do
      host = insert(:unverified_user, inserted_at: days_ago(400), last_active_at: days_ago(300))
      ended = days_ago(30)

      meeting =
        insert(:meeting,
          organizer_user: host,
          organizer_email: host.email,
          status: :completed,
          start_time: DateTime.add(ended, -30, :minute),
          end_time: ended
        )

      insert(:slack_integration, user: host)

      %{
        "action" => "send_reminder_emails",
        "meeting_id" => meeting.id,
        "reminder_value" => 1,
        "reminder_unit" => "hours"
      }
      |> EmailWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day))
      |> Oban.insert!()

      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        send(test_pid, {:post, url})
        {:ok, %Req.Response{status: 200, body: ""}}
      end)

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(UserSchema, host.id)
      assert_received {:post, "https://slack.com/api/auth.revoke"}
      assert all_enqueued(worker: EmailWorker) == []
    end

    test "deletes the account's dependent rows with it, as an erasure request would" do
      stale = insert(:unverified_user, inserted_at: days_ago(31))
      profile = insert(:profile, user: stale)

      assert :ok = perform_job(DataRetentionWorker, %{})

      refute Repo.get(UserSchema, stale.id)
      refute Repo.get(ProfileSchema, profile.id)
    end

    test "respects the unverified_account_retention_days argument" do
      user = insert(:unverified_user, inserted_at: days_ago(10))

      assert :ok =
               perform_job(DataRetentionWorker, %{"unverified_account_retention_days" => 40})

      assert Repo.get(UserSchema, user.id)

      assert :ok = perform_job(DataRetentionWorker, %{"unverified_account_retention_days" => 7})
      refute Repo.get(UserSchema, user.id)
    end

    test "a zero or negative window deletes nothing" do
      user = insert(:unverified_user, inserted_at: days_ago(1))

      for days <- [0, -1] do
        assert :ok =
                 perform_job(DataRetentionWorker, %{"unverified_account_retention_days" => days})
      end

      assert Repo.get(UserSchema, user.id)
    end
  end
end
