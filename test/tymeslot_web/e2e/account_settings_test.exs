defmodule TymeslotWeb.E2E.AccountSettingsTest do
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :profiles

  feature "user changes password from account settings", %{session: session} do
    # A realistic address, longer than the factory's `user<n>@example.com`. An
    # email has no natural break points, so the account card only fits at 320px
    # if the layout breaks it. With the factory default the check below passed
    # or failed on the sequence number, i.e. on how many users earlier tests had
    # inserted, and so on test order.
    {session, user} =
      log_in_via_browser(session, %{email: "firstname.lastname@example-company.com"})

    new_password = "NewSecurePass456!"

    session =
      session
      |> visit("/dashboard/account")
      |> wait_for_live()

    # Open the password change form. Submitting it empty first shows the
    # form's own errors: it sets `novalidate`, so the browser lets the empty
    # required fields through to the server instead of blocking the submit.
    session =
      session
      |> click(css("button[phx-click='toggle_password_form']"))
      |> click(css("form[phx-submit='update_password'] button[type='submit']"))
      |> assert_has(css("#account-password-form .form-field-error", minimum: 1))
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
