defmodule TymeslotWeb.E2E.LoginTest do
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :auth

  test "user can log in with valid credentials", %{session: session} do
    user = create_onboarded_user()

    session
    |> visit("/auth/login")
    |> fill(by_label("Email Address"), user.email)
    |> fill(by_css("#password-input"), default_password())
    |> click(by_css("button[type='submit']"))
    |> wait_for_dashboard()
    |> assert_has(by_css("#dashboard-root"))
  end

  test "login with invalid credentials shows error", %{session: session} do
    user = create_onboarded_user()

    session
    |> visit("/auth/login")
    |> fill(by_label("Email Address"), user.email)
    |> fill(by_css("#password-input"), "WrongPassword99!")
    |> click(by_css("button[type='submit']"))
    |> assert_has(filter(by_css(".bg-red-50"), visible: true))
  end

  # The login form leaves validation to the app (`novalidate`): an empty
  # submit reaches the server and comes back with the app's own message,
  # not the browser's bubble.
  test "an empty login is answered by the app's own message", %{session: session} do
    session
    |> visit("/auth/login")
    |> refute_has(filter(by_css(".bg-red-50"), visible: true))
    |> click(by_css("button[type='submit']"))
    |> assert_has(filter(by_css(".bg-red-50"), visible: true))
    |> assert(page_url(&(&1.path == "/auth/login")))
  end

  test "login page fits the narrowest supported viewport", %{session: session} do
    session
    |> resize_to_mobile()
    |> visit("/auth/login")
    |> assert_has(by_css("#password-input"))
    |> assert_no_horizontal_overflow("login page at 320px")
  end
end
