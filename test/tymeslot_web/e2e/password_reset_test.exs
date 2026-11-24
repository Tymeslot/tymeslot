defmodule TymeslotWeb.E2E.PasswordResetTest do
  use TymeslotWeb.BrowserCase, async: true

  @moduletag :e2e
  @moduletag :auth

  import Mox, only: [verify_on_exit!: 1]

  setup :verify_on_exit!

  # Override the default stub to capture the reset URL before the Oban job
  # delivers it. The plaintext token is only available at generation time —
  # the DB stores only a hash, so we cannot recover it from there.
  setup do
    test_pid = self()

    Mox.expect(Tymeslot.EmailServiceMock, :send_password_reset, 1, fn _user, reset_url ->
      send(test_pid, {:password_reset_url, reset_url})
      {:ok, :sent}
    end)

    :ok
  end

  test "user can request password reset, set new password, and log in", %{session: session} do
    user = create_onboarded_user()

    # Request password reset
    session =
      session
      |> visit("/auth/login")
      |> click(by_css("button[phx-value-to='reset_password']"))
      # The login form has an "Email Address" field too; filling before the
      # view swaps in the reset form would sign in with no password.
      |> assert_has(by_css("#reset-password-form"))
      |> fill(by_label("Email Address"), user.email)
      |> click(by_css("button[type='submit']"))

    # Should show confirmation
    assert_has(session, by_css("a[href='/auth/login']"))

    # Drain the Oban :emails queue to trigger the mock and capture the reset URL.
    # The job is inserted synchronously during the HTTP request, so it is
    # guaranteed to be in the queue by the time the browser test asserts the confirmation.
    Oban.drain_queue(queue: :emails)

    assert_receive {:password_reset_url, reset_url}, 2_000
    "/auth/reset-password/" <> token = URI.parse(reset_url).path

    # Visit the reset password form with the plaintext token
    new_password = "NewSecurePass123!"

    session =
      session
      |> visit("/auth/reset-password/#{token}")
      |> fill(by_css("#password-input"), new_password)
      |> fill(by_css("#confirm-password-input"), new_password)
      |> click(by_css("button[type='submit']"))

    # Should show success page with a "Log In" button
    assert_has(session, filter(by_css("button"), has_text: "Log In"))

    # Log in with the new password
    session
    |> visit("/auth/login")
    |> fill(by_label("Email Address"), user.email)
    |> fill(by_css("#password-input"), new_password)
    |> click(by_css("button[type='submit']"))
    |> wait_for_dashboard()
  end
end
