defmodule TymeslotWeb.SignInReturnToJourneyTest do
  @moduledoc """
  A signed-out host who follows a link to one booking signs in and lands on
  that booking, by every way of signing in: the password form, a social
  provider, the end of a social sign-up, and the emailed verification link
  that signs a new account in. A session that lapses while a page is open
  goes to the plain login page instead, since the open page cannot name
  itself. Driven through the router, with only the providers' HTTP stubbed.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :auth
  @moduletag :controllers
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.Test.OAuthProviderStub

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Tymeslot.Auth.Session
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Password

  @password "Password1234!"

  setup :setup_providers

  setup do
    original_legal = Application.get_env(:tymeslot, :enforce_legal_agreements, false)
    Application.put_env(:tymeslot, :enforce_legal_agreements, false)
    on_exit(fn -> Application.put_env(:tymeslot, :enforce_legal_agreements, original_legal) end)

    host =
      insert(:user,
        password_hash: Password.hash_password(@password),
        verified_at: DateTime.utc_now(),
        onboarding_completed_at: DateTime.utc_now()
      )

    insert(:profile, user: host)

    booking =
      insert(:meeting,
        organizer_user_id: host.id,
        organizer_email: host.email,
        attendee_name: "Linked Booking Guest",
        start_time: DateTime.add(DateTime.utc_now(), 1, :day),
        end_time: DateTime.add(DateTime.utc_now(), 24 * 60 + 30, :minute)
      )

    %{host: host, link: "/dashboard/meetings?meeting=#{booking.id}"}
  end

  # A signed-out visitor follows `link`: the guard sends them to the login
  # page, which they open. Returns the conn that opened it.
  defp follow_signed_out(conn, link) do
    conn = get(conn, link)
    login = redirected_to(conn)
    assert login == "/auth/login?" <> URI.encode_query(%{"redirect_to" => link})

    conn |> recycle() |> get(login)
  end

  defp password_sign_in(conn, email, password \\ @password),
    do: conn |> recycle() |> post(~p"/auth/session", %{"email" => email, "password" => password})

  describe "the password form" do
    test "lands on the linked booking, which shows", %{conn: conn, host: host, link: link} do
      conn = conn |> follow_signed_out(link) |> password_sign_in(host.email)

      assert redirected_to(conn) == link

      {:ok, view, _html} = conn |> recycle() |> live(link)
      assert render(view) =~ "Linked Booking Guest"
      assert render(view) =~ "Showing one booking."
    end

    test "still lands there after a wrong password, whose error is in the visitor's language",
         %{conn: conn, host: host, link: link} do
      conn =
        conn
        |> put_req_header("accept-language", "de")
        |> follow_signed_out(link)
        |> password_sign_in(host.email, "not-the-password")

      assert redirected_to(conn) == "/auth/login"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Ungültige E-Mail-Adresse oder ungültiges Passwort. Falls Sie sich kürzlich registriert haben, finden Sie den Bestätigungslink in Ihrem Posteingang."

      conn = password_sign_in(conn, host.email)
      assert redirected_to(conn) == link
    end

    test "uses the page once: the next sign-in on the browser goes to the dashboard",
         %{conn: conn, host: host, link: link} do
      conn = conn |> follow_signed_out(link) |> password_sign_in(host.email)
      assert redirected_to(conn) == link

      conn = conn |> recycle() |> delete(~p"/auth/logout")
      conn = conn |> recycle() |> get(~p"/auth/login") |> password_sign_in(host.email)

      assert redirected_to(conn) == "/dashboard"
    end

    test "a page too long to keep still opens the login page, and ends on the dashboard",
         %{conn: conn, host: host} do
      target = "/dashboard/meetings?q=" <> String.duplicate("a", 8_000)

      conn = get(conn, "/auth/login?" <> URI.encode_query(%{"redirect_to" => target}))
      assert html_response(conn, 200)

      assert redirected_to(password_sign_in(conn, host.email)) == "/dashboard"
    end

    for target <- ["https://evil.example/phish", "//evil.example/phish", "/\\evil.example"] do
      test "ignores a page off the site: #{target}", %{conn: conn, host: host} do
        conn =
          conn
          |> get("/auth/login?" <> URI.encode_query(%{"redirect_to" => unquote(target)}))
          |> password_sign_in(host.email)

        assert redirected_to(conn) == "/dashboard"
      end
    end
  end

  describe "a social provider" do
    test "lands on the linked booking after the provider's round trip",
         %{conn: conn, host: host, link: link} do
      host |> Changeset.change(github_user_id: "7001") |> Repo.update!()
      stub_github(%{"id" => 7001, "name" => "Host", "email" => host.email}, [])

      conn = conn |> follow_signed_out(link) |> recycle() |> sign_in("github")

      assert redirected_to(conn) == link
    end
  end

  describe "a social sign-up" do
    test "lands on the linked page once the registration form is complete", %{conn: conn} do
      link = "/dashboard/calendar"

      stub_github(%{"id" => 7002, "name" => "New Host", "email" => nil}, [
        %{"email" => "new-host@example.com", "primary" => true, "verified" => true}
      ])

      conn = conn |> follow_signed_out(link) |> recycle() |> sign_in("github")
      assert redirected_to(conn) == "/auth/complete-registration"

      conn =
        conn
        |> recycle()
        |> post(~p"/auth/complete", %{"auth" => %{}, "profile" => %{"full_name" => "New Host"}})

      assert redirected_to(conn) == link
      assert Repo.get_by!(UserSchema, github_user_id: "7002")
    end
  end

  describe "a session that lapses while a page is open" do
    test "leaves for the plain login page, and signing in goes to the dashboard", %{
      conn: conn,
      host: host,
      link: link
    } do
      conn = conn |> get(~p"/auth/login") |> password_sign_in(host.email)
      {:ok, view, _html} = conn |> recycle() |> live(~p"/dashboard")

      _deleted = Session.delete_session_rows(host.id)

      assert {:error, {:redirect, %{to: "/auth/login"}}} = live_redirect(view, to: link)

      conn = conn |> recycle() |> get(~p"/auth/login") |> password_sign_in(host.email)
      assert redirected_to(conn) == "/dashboard"
    end
  end

  describe "the emailed verification link" do
    test "signs a new account in on the linked page", %{conn: conn, link: link} do
      token = "return-to-verification-token"
      user = insert(:user, verified_at: nil, signup_ip: "127.0.0.1")
      {:ok, _user} = UserTokenQueries.set_verification_token(user, token, "127.0.0.1")

      conn =
        conn |> follow_signed_out(link) |> recycle() |> post(~p"/auth/verify-complete/#{token}")

      assert redirected_to(conn) == link
    end
  end
end
