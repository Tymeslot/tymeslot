defmodule Tymeslot.Auth.AccountDeletion.RequestTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Phoenix.Socket.Broadcast
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{UserSchema, UserSessionQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.{RateLimiter, Token}
  alias Tymeslot.Workers.{AccountDeletionWorker, EmailWorker}
  alias TymeslotWeb.Endpoint

  @opts [ip: "203.0.113.7", user_agent: "ExUnit"]
  @password "Password123!"

  defmodule RecordingHook do
    @behaviour Tymeslot.Auth.Behaviours.AccountDeletionHook

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_requested(user_id, feedback) do
      send(self(), {:requested, user_id, feedback})
      :ok
    end

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_deletion_restored(_user_id), do: :ok

    @impl Tymeslot.Auth.Behaviours.AccountDeletionHook
    def on_account_deletion(_user_id), do: :ok
  end

  setup do
    RateLimiter.clear_all()

    with_config(:tymeslot,
      account_deletion_grace_days: 14,
      collect_deletion_feedback: true,
      account_deletion_hook: RecordingHook
    )

    :ok
  end

  defp socket_topic(token), do: "users_sessions:#{Base.url_encode64(Token.hash_token(token))}"

  defp session_for(user) do
    token = "session-#{System.unique_integer([:positive])}"
    insert(:user_session, user: user, token_hash: Token.hash_token(token))
    token
  end

  test "schedules the deletion after the grace period and freezes the account" do
    user = insert(:user)
    user_id = user.id
    session = session_for(user)
    :ok = Auth.subscribe_to_account(user.id)

    params = %{
      "current_password" => @password,
      "reason" => "too_expensive",
      "comment" => "Too dear"
    }

    assert {:ok, pending} = Auth.request_account_deletion(user, params, @opts)

    assert DateTime.diff(pending.deletion_scheduled_at, pending.deletion_requested_at, :day) == 14

    assert_enqueued(
      worker: AccountDeletionWorker,
      args: %{"user_id" => user_id},
      scheduled_at: pending.deletion_scheduled_at
    )

    assert_enqueued(
      worker: EmailWorker,
      args: %{
        "action" => "send_account_deletion_notice",
        "email" => user.email,
        "restorable" => true
      }
    )

    assert UserSessionQueries.get_user_by_session_token(session) == nil
    assert_received {:account_deletion_requested, ^user_id}
    assert_received {:requested, ^user_id, %{reason: "too_expensive", comment: "Too dear"}}
  end

  test "the notice job carries the owner's profile timezone" do
    user = insert(:user)
    insert(:profile, user: user, timezone: "Pacific/Kiritimati")

    assert {:ok, _pending} =
             Auth.request_account_deletion(user, %{"current_password" => @password}, @opts)

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_account_deletion_notice", "timezone" => "Pacific/Kiritimati"}
    )
  end

  test "a wrong password schedules nothing" do
    user = insert(:user)

    assert {:error, %{current_password: _message}} =
             Auth.request_account_deletion(user, %{"current_password" => "nope"}, @opts)

    assert Repo.get(UserSchema, user.id).deletion_scheduled_at == nil
    refute_enqueued(worker: AccountDeletionWorker)
  end

  test "an account that signs in through a provider confirms with its address" do
    user = insert(:user, provider: "google", password_hash: nil, email: "sam@example.com")

    assert {:error, %{confirm_email: _message}} =
             Auth.request_account_deletion(user, %{"confirm_email" => "other@example.com"}, @opts)

    assert {:ok, _pending} =
             Auth.request_account_deletion(
               user,
               %{"confirm_email" => "  SAM@example.com "},
               @opts
             )
  end

  test "with no grace period the deletion is due at once and the notice offers no restore" do
    with_config(:tymeslot, :account_deletion_grace_days, 0)
    user = insert(:user)

    assert {:ok, pending} =
             Auth.request_account_deletion(user, %{"current_password" => @password}, @opts)

    assert pending.deletion_scheduled_at == pending.deletion_requested_at

    assert_enqueued(
      worker: EmailWorker,
      args: %{"action" => "send_account_deletion_notice", "restorable" => false}
    )
  end

  test "a second request keeps the first schedule and repeats no side effect" do
    user = insert(:user)
    user_id = user.id
    params = %{"current_password" => @password}
    :ok = Auth.subscribe_to_account(user_id)

    assert {:ok, first} = Auth.request_account_deletion(user, params, @opts)
    assert {:ok, second} = Auth.request_account_deletion(first, params, @opts)

    assert second.deletion_scheduled_at == first.deletion_scheduled_at
    assert length(all_enqueued(worker: AccountDeletionWorker)) == 1
    assert length(all_enqueued(worker: EmailWorker)) == 1

    assert_received {:requested, ^user_id, _feedback}
    refute_received {:requested, _user_id, _feedback}
    assert_received {:account_deletion_requested, ^user_id}
    refute_received {:account_deletion_requested, _user_id}
  end

  test "the requesting session keeps its socket, every other session loses its" do
    user = insert(:user)
    current = session_for(user)
    other = session_for(user)
    current_topic = socket_topic(current)
    other_topic = socket_topic(other)
    Endpoint.subscribe(current_topic)
    Endpoint.subscribe(other_topic)

    assert {:ok, _pending} =
             Auth.request_account_deletion(
               user,
               %{"current_password" => @password},
               [current_session_token: current] ++ @opts
             )

    assert UserSessionQueries.get_user_by_session_token(current) == nil
    assert UserSessionQueries.get_user_by_session_token(other) == nil
    assert_receive %Broadcast{event: "disconnect", topic: ^other_topic}
    refute_receive %Broadcast{event: "disconnect", topic: ^current_topic}
  end

  test "a refused request leaves the sessions alone" do
    user = insert(:user)
    session = session_for(user)

    assert {:error, _reason} =
             Auth.request_account_deletion(user, %{"current_password" => "nope"}, @opts)

    assert UserSessionQueries.get_user_by_session_token(session)
  end

  test "an account with a password confirms with it, even through a provider" do
    user = insert(:user, provider: "google")

    assert {:error, %{current_password: _message}} =
             Auth.request_account_deletion(user, %{"confirm_email" => user.email}, @opts)

    assert {:ok, _pending} =
             Auth.request_account_deletion(user, %{"current_password" => @password}, @opts)
  end

  test "no feedback reaches the hook while collection is off" do
    with_config(:tymeslot, :collect_deletion_feedback, false)
    user = insert(:user)
    user_id = user.id

    assert {:ok, _pending} =
             Auth.request_account_deletion(
               user,
               %{"current_password" => @password, "reason" => "too_expensive"},
               @opts
             )

    assert_received {:requested, ^user_id, nil}
  end

  test "repeated wrong passwords hit the login rate limit" do
    user = insert(:user)

    message =
      Enum.find_value(1..30, fn _attempt ->
        case Auth.request_account_deletion(user, %{"current_password" => "nope"}, @opts) do
          {:error, :rate_limited, message} -> message
          _other -> nil
        end
      end)

    assert message =~ ~r/\S/
  end

  test "the notice is queued by the request alone, and a conflicting job does not fail it" do
    user = insert(:user)
    {:ok, _job} = AccountDeletionWorker.schedule(user.id, DateTime.utc_now())

    assert {:ok, _pending} =
             Auth.request_account_deletion(user, %{"current_password" => @password}, @opts)

    assert length(all_enqueued(worker: AccountDeletionWorker)) == 1
    assert length(all_enqueued(worker: EmailWorker)) == 1
  end

  describe "the last admin who can sign in" do
    test "is refused, and the account stays as it was" do
      admin = insert(:user, is_admin: true)

      assert {:error, %{base: message}} =
               Auth.request_account_deletion(admin, %{"current_password" => @password}, @opts)

      assert message =~ "only admin who can sign in"
      refute Repo.reload!(admin).deletion_scheduled_at
      refute_enqueued(worker: AccountDeletionWorker)
    end

    test "can ask once another admin who can sign in remains" do
      admin = insert(:user, is_admin: true)
      _other_admin = insert(:user, is_admin: true)

      assert {:ok, %UserSchema{deletion_scheduled_at: %DateTime{}}} =
               Auth.request_account_deletion(admin, %{"current_password" => @password}, @opts)
    end

    test "is refused when the other admin is already pending deletion" do
      admin = insert(:user, is_admin: true)

      _leaving_admin =
        insert(:user,
          is_admin: true,
          deletion_requested_at: DateTime.utc_now(:second),
          deletion_scheduled_at: DateTime.add(DateTime.utc_now(:second), 14, :day)
        )

      assert {:error, %{base: _message}} =
               Auth.request_account_deletion(admin, %{"current_password" => @password}, @opts)

      refute Repo.reload!(admin).deletion_scheduled_at
    end
  end
end
