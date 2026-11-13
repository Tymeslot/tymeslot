defmodule TymeslotWeb.OnboardingLocaleTest do
  @moduledoc """
  The setup wizard speaks the host's language: the saved interface language
  of a signed-in host decides the wizard's copy, on the real route.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import TymeslotWeb.OnboardingTestHelpers

  test "a host whose language is German sees the wizard in German", %{conn: conn} do
    {:ok, view, html, _user} = setup_onboarding(setup_onboarding_session(conn), %{locale: "de"})

    assert html =~ "Ihr Link"
    assert render(view) =~ "Ihr Link"
    refute render(view) =~ "Your link"
  end

  test "a host without a saved language sees English", %{conn: conn} do
    {:ok, view, _html, _user} = setup_onboarding(setup_onboarding_session(conn))

    assert render(view) =~ "Your link"
  end
end
