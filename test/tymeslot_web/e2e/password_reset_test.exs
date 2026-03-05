defmodule TymeslotWeb.E2E.PasswordResetTest do
  use TymeslotWeb.BrowserCase

  @moduletag :e2e

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

  feature "user can request password reset, set new password, and log in", %{session: session} do
    user = create_onboarded_user()

    # Request password reset
    session =
      session
      |> visit("/auth/login")
      |> wait_for_live()
      |> click(css("button[phx-value-state='reset_password']"))
      |> fill_in(text_field("email"), with: user.email)
      |> click(css("button[type='submit']"))

    # Should show confirmation
    assert_has(session, css("a[href='/auth/login']"))

    # Drain the Oban :emails queue to trigger the mock and capture the reset URL.
    # The job is inserted synchronously during the HTTP request, so it is
    # guaranteed to be in the queue by the time Wallaby asserts the confirmation.
    Oban.drain_queue(queue: :emails)

    assert_receive {:password_reset_url, reset_url}, 2_000
    "/auth/reset-password/" <> token = URI.parse(reset_url).path

    # Visit the reset password form with the plaintext token
    new_password = "NewSecurePass123!"

    session =
      session
      |> visit("/auth/reset-password/#{token}")
      |> wait_for_live()
      |> fill_in(css("#password-input"), with: new_password)
      |> fill_in(css("#confirm-password-input"), with: new_password)
      |> click(css("button[type='submit']"))

    # Should show success page with a "Log In" button
    assert_has(session, css("button", text: "Log In"))

    # Log in with the new password
    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(text_field("email"), with: user.email)
    |> fill_in(css("#password-input"), with: new_password)
    |> click(css("button[type='submit']"))
    |> wait_for_dashboard()
  end
end
