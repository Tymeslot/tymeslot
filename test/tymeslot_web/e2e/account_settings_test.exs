defmodule TymeslotWeb.E2E.AccountSettingsTest do
  use TymeslotWeb.BrowserCase

  @moduletag :e2e

  feature "user changes password from account settings", %{session: session} do
    {session, _user} = log_in_via_browser(session)
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

    # Should see success flash (role=alert from flash component)
    assert_has(session, css("[role='alert']", text: "Password updated"))
  end
end
