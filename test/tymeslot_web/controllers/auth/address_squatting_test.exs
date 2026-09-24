defmodule TymeslotWeb.Auth.AddressSquattingTest do
  @moduledoc """
  Someone signs up with an address they do not own. They must learn nothing
  from signing in with the password they chose, and the address's real owner
  must be able to take the account back through the mailbox.
  """

  use TymeslotWeb.ConnCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :auth
  @moduletag :integration

  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Tymeslot.Auth.{PasswordReset, Registration, UserSchema, UserSessionSchema}
  alias Tymeslot.Emails.EmailScheduler.LinkArg
  alias Tymeslot.Repo
  alias Tymeslot.Security.Password
  alias Tymeslot.Workers.EmailWorker
  alias TymeslotWeb.Helpers.ClientIP

  @attacker_password "Attacker123!pw"
  @owner_password "OwnerChosen456!pw"

  defp sign_in(conn, email, password),
    do: post(conn, ~p"/auth/session", %{"email" => email, "password" => password})

  defp outcome(conn),
    do: {redirected_to(conn), Flash.get(conn.assigns.flash, :error), get_session(conn)}

  defp reset_token(user_id) do
    [job] =
      all_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_password_reset", "user_id" => user_id}
      )

    {:ok, url} = LinkArg.fetch(job.args, "reset_url")
    url |> URI.parse() |> Map.fetch!(:path) |> String.split("/") |> List.last()
  end

  test "the squatter learns nothing, and the owner reclaims the address by resetting",
       %{conn: conn} do
    victim = "victim-#{System.unique_integer([:positive])}@example.com"
    taken = insert(:user, password_hash: Password.hash_password("Somebody123!pw"))

    # The squatter signs up with the victim's address and a password they know.
    assert {:ok, squatted, _message} =
             Registration.register_user(
               %{
                 "email" => victim,
                 "password" => @attacker_password,
                 "terms_accepted" => "true"
               },
               ClientIP.request_opts(%Plug.Conn{})
             )

    # Signing in with that correct password looks exactly like a wrong password
    # on an address someone else already holds.
    assert outcome(sign_in(conn, victim, @attacker_password)) ==
             outcome(sign_in(build_conn(), taken.email, "WrongGuess123!"))

    # A session somehow held for the squatted account must not survive either.
    session = insert(:user_session, user: squatted)

    # The owner asks for a reset and follows the emailed link.
    assert {:ok, :reset_initiated, _message} = PasswordReset.initiate_reset(victim)

    assert {:ok, _user, _message} =
             PasswordReset.reset_password(
               reset_token(squatted.id),
               @owner_password,
               @owner_password
             )

    # Resetting through the mailbox proves the address, so the account is now
    # verified and the owner is signed straight in.
    assert Repo.get!(UserSchema, squatted.id).verified_at
    refute Repo.get(UserSessionSchema, session.id)

    owner = sign_in(build_conn(), victim, @owner_password)
    assert redirected_to(owner) == "/dashboard"
    assert get_session(owner, :user_token)

    # The squatter's password is gone.
    squatter = sign_in(build_conn(), victim, @attacker_password)
    assert redirected_to(squatter) == "/auth/login"
    refute get_session(squatter, :user_token)
  end
end
