defmodule Tymeslot.Auth.RegistrationDuplicateTest do
  @moduledoc """
  Signing up with an address that already has an account must be
  indistinguishable from signing up with a free one: the same reply, and the
  explanation sent only to the address's owner.
  """

  # async: false: one test swaps the configured user-queries module to
  # simulate a concurrent sign-up, which is global application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Auth.{Registration, UserSchema}
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Helpers.ClientIP

  defmodule RacingUserQueries do
    @moduledoc false
    # Another sign-up for the same address commits between the uniqueness
    # check and this sign-up's insert: the first lookup still sees no account,
    # and the insert then meets the unique index.
    alias Tymeslot.Auth.{UserQueries, UserSchema}

    @spec get_user_by_email(String.t()) :: {:ok, UserSchema.t()} | {:error, :not_found}
    def get_user_by_email(email) do
      if Process.get(:racing_lookup_done) do
        UserQueries.get_user_by_email(email)
      else
        Process.put(:racing_lookup_done, true)
        {:error, :not_found}
      end
    end

    @spec create_user(map()) :: {:ok, UserSchema.t()} | {:error, Ecto.Changeset.t()}
    def create_user(attrs), do: UserQueries.create_user(attrs)
  end

  defp params(email) do
    %{
      "email" => email,
      "password" => "ValidPassword123!",
      "password_confirmation" => "ValidPassword123!",
      "terms_accepted" => "true"
    }
  end

  defp unique_email(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}@example.com"

  defp notices do
    all_enqueued(worker: EmailWorker, args: %{"action" => "send_signup_attempt_notice"})
  end

  test "a taken address gets the same reply as a free one, and no account" do
    password_owner = insert(:user)
    social_owner = insert(:user, provider: "google", password_hash: nil)

    {:ok, _new_user, new_message} =
      Registration.register_user(
        params(unique_email("fresh")),
        ClientIP.request_opts(%Plug.Conn{})
      )

    for owner <- [password_owner, social_owner] do
      assert {:existing_account, ^new_message} =
               Registration.register_user(
                 params(String.upcase(owner.email)),
                 ClientIP.request_opts(%Plug.Conn{})
               )
    end

    assert Repo.aggregate(UserSchema, :count, :id) == 3
  end

  test "the owner of a taken address is sent the sign-up attempt notice" do
    owner = insert(:user)

    Registration.register_user(params(owner.email), ClientIP.request_opts(%Plug.Conn{}))

    assert [notice] = notices()
    assert notice.args["user_id"] == owner.id

    # No verification email goes anywhere for the attempt.
    assert [] =
             all_enqueued(worker: EmailWorker, args: %{"action" => "send_email_verification"})
  end

  test "a free address gets the verification email and no notice" do
    email = unique_email("fresh")

    {:ok, user, _message} =
      Registration.register_user(params(email), ClientIP.request_opts(%Plug.Conn{}))

    assert [_verification] =
             all_enqueued(
               worker: EmailWorker,
               args: %{"action" => "send_email_verification", "user_id" => user.id}
             )

    assert [] = notices()
  end

  test "the notice is capped per recipient, while the reply stays the same" do
    owner = insert(:user)

    for _i <- 1..5, do: RateLimiter.check_signup_attempt_notice_rate_limit(owner.id)

    assert {:existing_account, _message} =
             Registration.register_user(params(owner.email), ClientIP.request_opts(%Plug.Conn{}))

    assert [] = notices()
  end

  test "a concurrent sign-up that wins the unique index is answered as a duplicate" do
    original = Application.get_env(:tymeslot, :user_queries_module)
    Application.put_env(:tymeslot, :user_queries_module, RacingUserQueries)

    on_exit(fn ->
      if original,
        do: Application.put_env(:tymeslot, :user_queries_module, original),
        else: Application.delete_env(:tymeslot, :user_queries_module)
    end)

    winner = insert(:user, email: unique_email("race"))

    assert {:existing_account, message} =
             Registration.register_user(params(winner.email), ClientIP.request_opts(%Plug.Conn{}))

    assert message =~ "Please check your email"
    assert Repo.aggregate(UserSchema, :count, :id) == 1
    assert [notice] = notices()
    assert notice.args["user_id"] == winner.id
  end

  describe "the address's verification allowance" do
    defp conn_from(ip), do: ClientIP.request_opts(%Plug.Conn{remote_ip: ip})

    # Resends the address may still make before the verification limit
    # refuses it.
    defp remaining_resends(ip_string) do
      Enum.count(1..10, fn _i ->
        RateLimiter.check_verification_ip_rate_limit(ip_string) == :ok
      end)
    end

    test "a new and a taken sign-up spend the same allowance" do
      owner = insert(:user)

      {:ok, _user, _message} =
        Registration.register_user(params(unique_email("fresh")), conn_from({198, 51, 100, 31}))

      {:existing_account, _message} =
        Registration.register_user(params(owner.email), conn_from({198, 51, 100, 32}))

      assert remaining_resends("198.51.100.31") == 4
      assert remaining_resends("198.51.100.32") == 4
    end

    test "with the allowance used up, a free address is answered like a taken one" do
      owner = insert(:user)
      conn = conn_from({198, 51, 100, 33})
      for _i <- 1..5, do: RateLimiter.check_verification_ip_rate_limit("198.51.100.33")

      fresh = unique_email("fresh")
      assert {:ok, user, message} = Registration.register_user(params(fresh), conn)
      assert {:existing_account, ^message} = Registration.register_user(params(owner.email), conn)

      # The account exists; its verification email simply waits for a resend.
      assert user.email == fresh

      assert [] =
               all_enqueued(worker: EmailWorker, args: %{"action" => "send_email_verification"})
    end
  end
end
