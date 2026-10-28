defmodule TymeslotWeb.Integration.AuthEmailJourneyTest do
  @moduledoc """
  The two account journeys that pass through the visitor's inbox, walked
  without a browser: sign up, open the verification email and follow its
  link, then log in; and ask for a password reset, follow the emailed link,
  choose a new password, then log in with it.

  Each step goes through the page or controller a visitor reaches, and the
  link is read out of the email actually delivered, so a broken template URL,
  a token the email carries but the page rejects, or an email never sent
  fails here. The browser versions in `test/tymeslot_web/e2e/` skip the
  inbox and do not run in CI.
  """

  # async: false: `:shared_test_process` is global, and the emails are sent
  # from the Oban jobs drained in this process.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :auth

  import Mox
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, RateLimiter}

  @password "ValidPassword123!"

  setup do
    # The real emails, rendered and handed to the Swoosh test adapter.
    stub_with(Tymeslot.EmailServiceMock, Tymeslot.Emails.EmailService)
    Application.put_env(:swoosh, :shared_test_process, self())
    RateLimiter.clear_all()

    on_exit(fn ->
      Application.delete_env(:swoosh, :shared_test_process)
      RateLimiter.clear_all()
    end)

    :ok
  end

  test "a new account is verified from its email and can then log in", %{conn: conn} do
    email = "journey-signup-#{System.unique_integer([:positive])}@example.com"

    {:ok, view, _html} = live(conn, ~p"/auth/signup")

    view
    |> form("#signup-form", %{"user" => %{"email" => email, "password" => @password}})
    |> render_submit()

    assert_patch(view, ~p"/auth/verify-email")

    # Unverified, the password alone does not get in.
    refused = log_in(email, @password)
    assert redirected_to(refused) == ~p"/auth/login"
    assert Flash.get(refused.assigns.flash, :error)

    link = deliver_and_follow(email, ~r{/auth/verify-complete/[^"\s<]+})

    # Opening the link only shows a confirmation button; it does not verify.
    landing = get(build_conn(), link)
    assert html_response(landing, 200) =~ "Verify email address"
    refute Repo.get_by!(UserSchema, email: email).verified_at

    confirmed = post(build_conn(), link)
    assert redirected_to(confirmed) =~ ~r{^/(dashboard|onboarding)}
    assert Repo.get_by!(UserSchema, email: email).verified_at

    assert_logged_in(log_in(email, @password))
  end

  test "a forgotten password is replaced from the emailed link and the new one logs in",
       %{conn: conn} do
    user = insert(:user, password_hash: Password.hash_password(@password))
    new_password = "BrandNewSecret456!"

    {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

    view
    |> form("#reset-password-form", %{"email" => user.email})
    |> render_submit()

    assert_patch(view, ~p"/auth/reset-password-sent")

    link = deliver_and_follow(user.email, ~r{/auth/reset-password/[^"\s<]+})

    {:ok, form_view, _html} = live(build_conn(), link)

    form_view
    |> form("#new-password-form", %{
      "password" => new_password,
      "password_confirmation" => new_password
    })
    |> render_submit()

    assert render(form_view) =~ "Password Reset Successfully"

    refused = log_in(user.email, @password)
    assert redirected_to(refused) == ~p"/auth/login"

    assert_logged_in(log_in(user.email, new_password))
  end

  # Runs the queued email jobs, takes the one email sent to `address`, and
  # returns the path of the link in it that matches `pattern`.
  defp deliver_and_follow(address, pattern) do
    assert %{failure: 0} = Oban.drain_queue(queue: :emails)

    assert_received {:email, %Swoosh.Email{to: [{_name, ^address}]} = email}
    refute_received {:email, _another}

    assert [path] = Regex.run(pattern, email.html_body)
    assert email.text_body =~ path

    path
  end

  defp log_in(email, password) do
    post(build_conn(), ~p"/auth/session", %{"email" => email, "password" => password})
  end

  defp assert_logged_in(conn) do
    assert redirected_to(conn) =~ ~r{^/(dashboard|onboarding)}
    assert get_session(conn, :user_token)
  end
end
