defmodule TymeslotWeb.AccountLiveCredentialsTest do
  @moduledoc """
  The account page's password and email forms as a whole: every invalid
  field reported at once, and a password change revoking a token issued
  after the page loaded its copy of the user.
  """
  use TymeslotWeb.ConnCase, async: false

  @moduletag :auth

  import Phoenix.LiveViewTest
  import Tymeslot.TestFixtures
  import Tymeslot.AuthTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Auth
  alias Tymeslot.Auth.{UserSchema, UserTokenQueries}
  alias Tymeslot.Repo
  alias Tymeslot.Security.{RateLimiter, Token}
  alias TymeslotWeb.Helpers.ClientIP

  setup %{conn: conn} do
    RateLimiter.clear_all()

    {:ok, user} =
      create_user_fixture()
      |> Changeset.change(%{
        verified_at: DateTime.utc_now(:second),
        onboarding_completed_at: DateTime.utc_now(:second)
      })
      |> Repo.update()

    %{conn: log_in_user(conn, user), user: user}
  end

  describe "password form" do
    test "a password change revokes an email change requested after the page loaded", %{
      conn: conn,
      user: user
    } do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      # Meanwhile, someone else who knows the password redirects the account.
      change_token = Token.generate()

      {:ok, _pending} =
        UserTokenQueries.request_email_change(user, "attacker@example.com", change_token)

      view |> element("button", "Change Password") |> render_click()

      view
      |> form("form[phx-submit='update_password']", %{
        "password_form" => %{
          "current_password" => "Password123!",
          "new_password" => "NewPassword123!",
          "new_password_confirmation" => "NewPassword123!"
        }
      })
      |> render_submit()

      assert_redirect(view, ~p"/auth/login")

      stored = Repo.get!(UserSchema, user.id)
      assert stored.pending_email == nil
      assert stored.email_change_token_hash == nil

      assert {:error, {:invalid_token, _message}} =
               Auth.verify_email_change(change_token, ClientIP.request_opts(%Plug.Conn{}))
    end

    test "shows an error on every invalid field at once", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Password") |> render_click()

      view
      |> form("form[phx-submit='update_password']", %{
        "password_form" => %{
          "current_password" => "",
          "new_password" => "short",
          "new_password_confirmation" => "short"
        }
      })
      |> render_submit()

      assert has_element?(view, ~s(input[name="password_form[current_password]"][aria-invalid]))
      assert has_element?(view, ~s(input[name="password_form[new_password]"][aria-invalid]))
    end
  end

  describe "email form" do
    test "shows an error on both fields when both are invalid", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/account")

      view |> element("button", "Change Email") |> render_click()

      view
      |> form("form[phx-submit='update_email']", %{
        "email_form" => %{"new_email" => "not-an-email", "current_password" => ""}
      })
      |> render_submit()

      assert has_element?(view, ~s(input[name="email_form[new_email]"][aria-invalid]))
      assert has_element?(view, ~s(input[name="email_form[current_password]"][aria-invalid]))
    end

    # A registered address must not be told apart from a free one anywhere the
    # requester can look: the answer, the pending notice before and after a
    # reload, and cancelling it.
    for {label, address} <- [
          {"a free address", "free.address@example.com"},
          {"another account's address", "registered@example.com"}
        ] do
      test "changing to #{label} reads as a pending change that can be cancelled", %{conn: conn} do
        create_user_fixture(%{email: "registered@example.com"})
        {:ok, view, _html} = live(conn, ~p"/dashboard/account")

        html = submit_email_change(view, unquote(address))

        assert html =~ "Verification email sent to #{unquote(address)}"
        refute html =~ "already in use"
        assert pending?(view, unquote(address))

        {:ok, reloaded, _html} = live(conn, ~p"/dashboard/account")
        assert pending?(reloaded, unquote(address))

        html = reloaded |> element(~s([phx-click="cancel_email_change"])) |> render_click()
        assert html =~ "Email change request cancelled"
        refute has_element?(reloaded, "h3", "Email Change Pending")
      end
    end
  end

  defp submit_email_change(view, address) do
    view |> element("button", "Change Email") |> render_click()

    view
    |> form("form[phx-submit='update_email']", %{
      "email_form" => %{"new_email" => address, "current_password" => "Password123!"}
    })
    |> render_submit()
  end

  defp pending?(view, address) do
    has_element?(view, "h3", "Email Change Pending") and has_element?(view, "strong", address)
  end
end
