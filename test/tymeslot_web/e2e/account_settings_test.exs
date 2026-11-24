defmodule TymeslotWeb.E2E.AccountSettingsTest do
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :profiles

  test "user changes password from account settings", %{session: session} do
    # A realistic address, longer than the factory's `user<n>@example.com`. An
    # email has no natural break points, so the account card only fits at 320px
    # if the layout breaks it. With the factory default the check below passed
    # or failed on the sequence number, i.e. on how many users earlier tests had
    # inserted, and so on test order.
    {session, user} =
      log_in(session, %{email: "firstname.lastname@example-company.com"})

    new_password = "NewSecurePass456!"

    session = visit(session, "/dashboard/account")

    # Open the password change form. Submitting it empty first shows the
    # form's own errors: it sets `novalidate`, so the browser lets the empty
    # required fields through to the server instead of blocking the submit.
    session =
      session
      |> click(by_css("button[phx-click='toggle_password_form']"))
      |> click(by_css("form[phx-submit='update_password'] button[type='submit']"))
      |> assert_has(
        by_css("#account-password-form .form-field-error")
        |> filter(visible: true)
        |> first()
      )
      |> fill(by_css("input[name='password_form[current_password]']"), default_password())
      |> fill(by_css("input[name='password_form[new_password]']"), new_password)
      |> fill(by_css("input[name='password_form[new_password_confirmation]']"), new_password)
      |> click(by_css("form[phx-submit='update_password'] button[type='submit']"))

    # Changing your own password revokes every session, so the user is signed out
    # and lands back on the login page.
    #
    # The flash proves the LiveView's own redirect got through. The revocation
    # spares the socket that asked for it; were it disconnected too, the reply
    # carrying the redirect would be lost, the form would sit frozen until the
    # client's reload-with-jitter (5 to 10 seconds) and the user would land
    # here with a "session expired" notice instead.
    session =
      session
      |> assert_has(by_css("#password-input"))
      |> assert_has(
        filter(by_css("#app-flash-group-info"), has_text: "Your password has been changed")
      )
      |> wait_for_live()

    # The new password is the one that now works.
    session =
      session
      |> fill(by_label("Email Address"), user.email)
      |> fill(by_css("#password-input"), new_password)
      |> click(by_css("button[type='submit']"))
      |> wait_for_dashboard()

    # Same screen at the narrowest supported viewport, reusing this session
    # rather than paying for another login.
    session
    |> resize_to_mobile()
    |> visit("/dashboard/account")
    |> assert_has(by_css("button[phx-click='toggle_password_form']"))
    |> assert_no_horizontal_overflow("account settings at 320px")
  end
end
