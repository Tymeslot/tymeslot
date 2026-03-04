defmodule TymeslotWeb.E2E.LoginTest do
  use TymeslotWeb.BrowserCase

  @moduletag :e2e

  feature "user can log in with valid credentials", %{session: session} do
    user = create_onboarded_user()

    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(text_field("email"), with: user.email)
    |> fill_in(css("#password-input"), with: default_password())
    |> click(css("button[type='submit']"))
    |> wait_for_dashboard()
  end

  feature "login with invalid credentials shows error", %{session: session} do
    user = create_onboarded_user()

    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(text_field("email"), with: user.email)
    |> fill_in(css("#password-input"), with: "WrongPassword99!")
    |> click(css("button[type='submit']"))
    |> assert_has(css(".bg-red-50"))
  end
end
