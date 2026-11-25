defmodule TymeslotWeb.E2E.LoginTest do
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :auth

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

  # The session controller refuses the password and redirects back with the
  # generic message, which names neither the email nor the password as wrong,
  # in the app layout flash group's error toast (`#app-flash-group-error`).
  feature "login with invalid credentials shows error", %{session: session} do
    user = create_onboarded_user()

    session =
      session
      |> visit("/auth/login")
      |> wait_for_live()
      |> fill_in(text_field("email"), with: user.email)
      |> fill_in(css("#password-input"), with: "WrongPassword99!")
      |> click(css("button[type='submit']"))
      |> assert_has(css("#app-flash-group-error", text: "Invalid email or password."))

    assert current_path(session) == "/auth/login"
  end

  # The login form leaves validation to the app (`novalidate`): an empty
  # submit reaches the server and comes back with the app's own message,
  # not the browser's bubble.
  feature "an empty login is answered by the app's own message", %{session: session} do
    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> assert_has(css("#app-flash-group-error", count: 0, visible: :any))
    |> click(css("button[type='submit']"))
    |> assert_has(css("#app-flash-group-error", text: "Please enter your email and password."))

    assert current_path(session) == "/auth/login"
  end

  feature "login page fits the narrowest supported viewport", %{session: session} do
    session
    |> resize_to_mobile()
    |> visit("/auth/login")
    |> wait_for_live()
    |> assert_has(css("#password-input"))
    |> assert_no_horizontal_overflow("login page at 320px")
  end
end
