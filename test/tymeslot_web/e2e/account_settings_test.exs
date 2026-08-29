defmodule TymeslotWeb.E2E.AccountSettingsTest do
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :profiles

  feature "user changes password from account settings", %{session: session} do
    {session, user} = log_in_via_browser(session)
    new_password = "NewSecurePass456!"

    session =
      session
      |> visit("/dashboard/account")
      |> wait_for_live()

    # Open the password change form
    session =
      session
      |> click(css("button[phx-click='toggle_password_form']"))
      |> fill_in(css("input[name='password_form[current_password]']"), with: default_password())
      |> fill_in(css("input[name='password_form[new_password]']"), with: new_password)
      |> fill_in(
        css("input[name='password_form[new_password_confirmation]']"),
        with: new_password
      )
      |> click(css("form[phx-submit='update_password'] button[type='submit']"))

    # Changing your own password revokes every session, so the user is signed out
    # and lands back on the login page.
    #
    # We deliberately don't assert the flash wording here. The LiveView redirects
    # with "Your password has been changed…", but the revocation's disconnect
    # broadcast tears the socket down first, so the browser reconnects and the
    # auth layer's own "Your session has expired…" notice is what actually wins.
    # Which of the two lands is a race; being signed out is not.
    session =
      session
      |> assert_has(css("#password-input"))
      |> wait_for_live()

    # The new password is the one that now works.
    session =
      session
      |> fill_in(text_field("email"), with: user.email)
      |> fill_in(css("#password-input"), with: new_password)
      |> click(css("button[type='submit']"))
      |> wait_for_dashboard()

    # Same screen at the narrowest supported viewport, reusing this session
    # rather than paying for another login.
    session
    |> resize_to_mobile()
    |> visit("/dashboard/account")
    |> wait_for_live()
    |> assert_has(css("button[phx-click='toggle_password_form']"))
    |> assert_no_horizontal_overflow("account settings at 320px")
  end
end
