defmodule TymeslotWeb.AccountDeletion.AccountDeletionJourneyTest do
  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Ecto.Query
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Auth.{UserSchema, UserSessionSchema}
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Profiles.ProfileSchema
  alias Tymeslot.Release
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Encryption, RateLimiter}
  alias Tymeslot.Slack.SlackIntegrationSchema

  alias Tymeslot.Workers.{
    AccountDeletionWorker,
    EmailWorker,
    SlackWorker,
    TelegramWorker,
    WebhookWorker
  }

  @password "Password123!"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    RateLimiter.clear_all()
    with_config(:tymeslot, account_deletion_hook: nil, collect_deletion_feedback: false)
    stub(Tymeslot.ZoomOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)
    :ok
  end

  defp in_an_hour, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  defp host(username) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now(:second))
    insert(:profile, user: user, username: username)
    user
  end

  defp request_deletion(conn, user) do
    {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/dashboard/account")
    view |> element("#danger-zone button", "Delete account") |> render_click()

    view
    |> form("#delete-account-form", delete_account: %{current_password: @password})
    |> render_submit()
  end

  defp sign_in(user) do
    post(build_conn(), ~p"/auth/session", %{"email" => user.email, "password" => @password})
  end

  defp make_overdue(user) do
    overdue = DateTime.add(DateTime.utc_now(:second), -1, :second)

    Repo.update_all(from(u in UserSchema, where: u.id == ^user.id),
      set: [deletion_scheduled_at: overdue]
    )
  end

  defp rows_referencing(user_id) do
    [
      {UserSchema, :id},
      {ProfileSchema, :user_id},
      {UserSessionSchema, :user_id},
      {MeetingSchema, :organizer_user_id},
      {MeetingTypeSchema, :user_id},
      {CalendarIntegrationSchema, :user_id},
      {VideoIntegrationSchema, :user_id},
      {SlackIntegrationSchema, :user_id}
    ]
    |> Enum.map(fn {schema, field} ->
      {schema, Repo.aggregate(from(r in schema, where: field(r, ^field) == ^user_id), :count)}
    end)
    |> Enum.reject(fn {_schema, count} -> count == 0 end)
  end

  test "a host with integrations and bookings is frozen, then deleted, and no guest is told",
       %{conn: conn} do
    with_config(:tymeslot, :account_deletion_grace_days, 14)

    with_config(:tymeslot, :zoom_oauth,
      client_id: "zoom-id",
      client_secret: "zoom-secret",
      state_secret: "zoom-state"
    )

    user = host("leaving-host")

    insert(:calendar_integration,
      user: user,
      provider: "google",
      google_channel_id: "chan-1",
      google_channel_resource_id: "res-1",
      access_token_encrypted: Encryption.encrypt("cal-access"),
      refresh_token_encrypted: Encryption.encrypt("cal-refresh"),
      token_expires_at: in_an_hour()
    )

    insert(:video_integration,
      user: user,
      provider: "zoom",
      access_token_encrypted: Encryption.encrypt("zoom-access"),
      refresh_token_encrypted: Encryption.encrypt("zoom-refresh"),
      token_expires_at: in_an_hour()
    )

    insert(:slack_integration, user: user)
    future = insert(:meeting, organizer_user: user, organizer_email: user.email)
    week_ago = DateTime.add(DateTime.utc_now(:second), -7, :day)

    past =
      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        start_time: week_ago,
        end_time: DateTime.add(week_ago, 1, :hour)
      )

    %{
      "action" => "send_reminder_emails",
      "meeting_id" => future.id,
      "reminder_value" => 1,
      "reminder_unit" => "hours"
    }
    |> EmailWorker.new(scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day))
    |> Oban.insert!()

    # 1. The host asks for the deletion and is signed out.
    assert {:error, {:redirect, %{to: "/auth/login"}}} = request_deletion(conn, user)

    assert [notice] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_account_deletion_notice"}
             )

    assert notice.args["email"] == user.email

    # 2. Frozen: no public page, and signing in only offers the restore page.
    assert_error_sent(404, fn -> get(build_conn(), "/leaving-host") end)
    signed_in = sign_in(user)
    assert redirected_to(signed_in) == "/dashboard"
    assert signed_in |> recycle() |> get(~p"/dashboard") |> redirected_to() == "/auth/restore"

    # 3. The grace period elapses: the restore is refused, then the job runs.
    make_overdue(user)
    refused = signed_in |> recycle() |> post(~p"/auth/restore")
    assert html_response(refused, 200) =~ "can no longer be restored"
    assert Repo.get(UserSchema, user.id).deletion_scheduled_at
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :request, fn :post, url, _body, _headers, _opts ->
      send(test_pid, {:called, url})
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    expect(Tymeslot.HTTPClientMock, :post, 3, fn url, _body, _headers, _opts ->
      send(test_pid, {:called, url})
      {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
    end)

    assert perform_job(AccountDeletionWorker, %{"user_id" => user.id}) == :ok

    # 4. What Tymeslot held at third parties was cleaned up.
    assert_received {:called, "https://www.googleapis.com/calendar/v3/channels/stop"}
    assert_received {:called, "https://oauth2.googleapis.com/revoke"}
    assert_received {:called, "https://zoom.us/oauth/revoke?token=zoom-access"}
    assert_received {:called, "https://slack.com/api/auth.revoke"}

    # 5. No row references the user, and nothing queued for its meetings remains.
    assert rows_referencing(user.id) == []
    refute Repo.get(MeetingSchema, past.id)

    assert Enum.filter(
             all_enqueued(worker: EmailWorker),
             &(&1.args["meeting_id"] in [future.id, past.id])
           ) ==
             []

    # 6. Nobody was told about the bookings that went.
    refute_enqueued(worker: EmailWorker, args: %{"action" => "send_cancellation_emails"})

    refute Enum.any?(
             all_enqueued(worker: EmailWorker),
             &(&1.args["email"] in [future.attendee_email, past.attendee_email])
           )

    assert [_only_one] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_account_deletion_notice"}
             )

    refute_enqueued(worker: WebhookWorker)
    refute_enqueued(worker: SlackWorker)
    refute_enqueued(worker: TelegramWorker)
  end

  test "a Google or Zoom account another host also connected stays connected for that host",
       %{conn: conn} do
    with_config(:tymeslot, :account_deletion_grace_days, 0)

    with_config(:tymeslot, :zoom_oauth,
      client_id: "zoom-id",
      client_secret: "zoom-secret",
      state_secret: "zoom-state"
    )

    leaving = host("leaving-sharer")
    staying = host("staying-sharer")

    insert(:calendar_integration,
      user: leaving,
      provider: "google",
      provider_account_id: "google-sub-shared",
      google_channel_id: "chan-1",
      google_channel_resource_id: "res-1",
      access_token_encrypted: Encryption.encrypt("cal-access"),
      refresh_token_encrypted: Encryption.encrypt("cal-refresh"),
      token_expires_at: in_an_hour()
    )

    insert(:video_integration,
      user: leaving,
      provider: "zoom",
      provider_account_id: "zoom-user-shared",
      access_token_encrypted: Encryption.encrypt("zoom-access"),
      refresh_token_encrypted: Encryption.encrypt("zoom-refresh"),
      token_expires_at: in_an_hour()
    )

    # The other host connected the same Google account for Meet, not for a
    # calendar, and the same Zoom user.
    staying_meet =
      insert(:video_integration,
        user: staying,
        provider: "google_meet",
        provider_account_id: "google-sub-shared",
        refresh_token_encrypted: Encryption.encrypt("meet-refresh")
      )

    staying_zoom =
      insert(:video_integration,
        user: staying,
        provider: "zoom",
        provider_account_id: "zoom-user-shared",
        access_token_encrypted: Encryption.encrypt("other-zoom-access")
      )

    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :request, fn :post, url, _body, _headers, _opts ->
      send(test_pid, {:called, url})
      {:ok, %Req.Response{status: 204, body: ""}}
    end)

    stub(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
      send(test_pid, {:called, url})
      {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert {:error, {:redirect, %{to: "/auth/login"}}} = request_deletion(conn, leaving)
    assert [job] = all_enqueued(worker: AccountDeletionWorker)
    assert perform_job(AccountDeletionWorker, job.args) == :ok

    # The leaving host's own channel is stopped and its rows are gone...
    assert_received {:called, "https://www.googleapis.com/calendar/v3/channels/stop"}
    assert rows_referencing(leaving.id) == []

    # ...but neither grant the other host relies on is revoked.
    refute_received {:called, "https://oauth2.googleapis.com/revoke"}
    refute_received {:called, "https://zoom.us/oauth/revoke" <> _query}

    assert Repo.get(VideoIntegrationSchema, staying_meet.id).refresh_token_encrypted
    assert Repo.get(VideoIntegrationSchema, staying_zoom.id).access_token_encrypted
  end

  test "self-hosted: with no grace period the account is deleted at once and never frozen",
       %{conn: conn} do
    with_config(:tymeslot, :account_deletion_grace_days, 0)
    user = host("instant-leaver")

    result = request_deletion(conn, user)
    assert {:error, {:redirect, %{to: "/auth/login"}}} = result
    {:ok, login} = follow_redirect(result, conn)
    assert html_response(login, 200) =~ "Your account has been deleted."

    assert [job] = all_enqueued(worker: AccountDeletionWorker)
    assert DateTime.compare(job.scheduled_at, DateTime.utc_now()) != :gt
    assert perform_job(AccountDeletionWorker, job.args) == :ok

    refute Repo.get(UserSchema, user.id)
    assert user |> sign_in() |> redirected_to() == "/auth/login"
  end

  test "restoring during the grace period keeps the account and its booking page",
       %{conn: conn} do
    with_config(:tymeslot, :account_deletion_grace_days, 14)
    user = host("second-thoughts")

    assert {:error, {:redirect, %{to: "/auth/login"}}} = request_deletion(conn, user)
    assert Profiles.get_profile_by_username("second-thoughts") == nil

    page = user |> sign_in() |> recycle() |> get(~p"/auth/restore")
    assert html_response(page, 200) =~ "Restore my account"

    restored = page |> recycle() |> post(~p"/auth/restore")
    assert redirected_to(restored) == "/dashboard"

    assert Repo.get(UserSchema, user.id).deletion_scheduled_at == nil
    refute_enqueued(worker: AccountDeletionWorker)
    assert Profiles.get_profile_by_username("second-thoughts")

    # The account works again: the dashboard opens and the booking page is back.
    assert restored |> recycle() |> get(~p"/dashboard") |> html_response(200)
    assert build_conn() |> get("/second-thoughts") |> html_response(200)
  end

  test "the only admin who can sign in is told to promote another first", %{conn: conn} do
    with_config(:tymeslot, :account_deletion_grace_days, 14)
    admin = host("sole-admin") |> Changeset.change(is_admin: true) |> Repo.update!()

    html = request_deletion(conn, admin)

    assert html =~ "You are the only admin who can sign in"
    assert Repo.get(UserSchema, admin.id).deletion_scheduled_at == nil
    refute_enqueued(worker: AccountDeletionWorker)
  end

  test "an admin left alone during the grace period is held, not deleted, and can restore",
       %{conn: conn} do
    with_config(:tymeslot, :account_deletion_grace_days, 14)
    admin = host("leaving-admin") |> Changeset.change(is_admin: true) |> Repo.update!()
    other = insert(:user, is_admin: true)

    assert {:error, {:redirect, %{to: "/auth/login"}}} = request_deletion(conn, admin)

    # The other admin goes during the grace period, forced from the release shell.
    assert {:ok, _demoted} = Release.demote_admin(other.email, true)
    make_overdue(admin)

    assert {:snooze, _seconds} = perform_job(AccountDeletionWorker, %{"user_id" => admin.id})
    assert Repo.get(UserSchema, admin.id)

    page = admin |> sign_in() |> recycle() |> get(~p"/auth/restore")
    assert html_response(page, 200) =~ "Restore my account"

    restored = page |> recycle() |> post(~p"/auth/restore")
    assert redirected_to(restored) == "/dashboard"
    assert Repo.get(UserSchema, admin.id).deletion_scheduled_at == nil
  end
end
