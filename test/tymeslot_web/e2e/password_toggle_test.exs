defmodule TymeslotWeb.E2E.PasswordToggleTest do
  @moduledoc """
  The eye button beside a password field (`PasswordToggle`, in
  `assets/js/password_toggle.js`) shows and hides what was typed, and keeps
  it shown when the server redraws the field with an error. On sign-up the
  same hook ticks the password checklist off as the rules are met, against
  the patterns the server enforces.
  """

  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :auth

  @password "#password-input"
  @toggle "#password-toggle"

  feature "the eye button shows and hides the password on the login page",
          %{session: session} do
    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(css(@password), with: "Secret123!")
    |> assert_hidden()
    |> click(css(@toggle))
    |> assert_shown()
    |> click(css(@toggle))
    |> assert_hidden()
  end

  feature "on sign-up the checklist ticks as rules are met, and a shown password stays shown",
          %{session: session} do
    session =
      session
      |> visit("/auth/signup")
      |> wait_for_live()
      |> fill_in(css(@password), with: "abcdefgh")
      |> assert_rules(met: ~w(length lowercase), unmet: ~w(uppercase number special))
      |> click(css(@toggle))
      |> assert_shown()
      |> fill_in(css("input[name='user[email]']"),
        with: "toggle-#{System.unique_integer()}@ex.com"
      )

    # The server refuses the password and redraws the field under its error;
    # the field stays shown.
    session =
      session
      |> click(css("#signup-form button[type='submit']"))
      |> assert_has(css("#signup-password-toggle-container", text: "uppercase letter"))
      |> assert_shown()

    session
    |> fill_in(css(@password), with: "Abcdefg1!")
    |> assert_rules(met: ~w(length lowercase uppercase number special), unmet: [])
  end

  # Any redraw of the form (here the email's own check when the field is left)
  # puts back the server's all-unmet checklist; the hook re-ticks it from the
  # field's value after every patch, not only on a keystroke.
  feature "on sign-up the checklist still reflects the password after the server redraws the form",
          %{session: session} do
    session
    |> visit("/auth/signup")
    |> wait_for_live()
    |> fill_in(css(@password), with: "abcdefgh")
    |> assert_rules(met: ~w(length lowercase), unmet: ~w(uppercase number special))
    |> fill_in(css("input[name='user[email]']"), with: "not-an-email")
    |> send_keys([:tab])
    |> assert_has(css("#signup-form", text: "Email format is invalid"))
    |> assert_rules(met: ~w(length lowercase), unmet: ~w(uppercase number special))
  end

  defp assert_shown(session) do
    session
    |> assert_has(css("#{@password}[type='text']"))
    |> assert_has(css("#{@toggle} [data-eye-closed]"))
    |> assert_has(css("#{@toggle} [data-eye-open]", visible: false))
  end

  defp assert_hidden(session) do
    session
    |> assert_has(css("#{@password}[type='password']"))
    |> assert_has(css("#{@toggle} [data-eye-open]"))
    |> assert_has(css("#{@toggle} [data-eye-closed]", visible: false))
  end

  # Each rule shows its tick once met and its empty circle until then.
  defp assert_rules(session, met: met, unmet: unmet) do
    session =
      Enum.reduce(met, session, fn rule, session ->
        session
        |> assert_has(css("#req-#{rule} [data-rule-met]"))
        |> assert_has(css("#req-#{rule} [data-rule-unmet]", visible: false))
      end)

    Enum.reduce(unmet, session, fn rule, session ->
      session
      |> assert_has(css("#req-#{rule} [data-rule-unmet]"))
      |> assert_has(css("#req-#{rule} [data-rule-met]", visible: false))
    end)
  end
end
