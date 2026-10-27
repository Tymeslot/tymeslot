defmodule TymeslotWeb.OnboardingLive.InitializerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :onboarding

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.Repo
  alias TymeslotWeb.OnboardingLive.Initializer

  test "sends the visitor back to sign-in when the account was deleted meanwhile" do
    user = insert(:user, onboarding_completed_at: nil)
    Repo.delete!(user)

    socket = %Socket{
      assigns: %{__changed__: %{}, current_user: user},
      endpoint: TymeslotWeb.Endpoint,
      transport_pid: self()
    }

    assert Initializer.initialize(socket, user).redirected ==
             {:redirect, %{to: "/auth/login", status: 302}}
  end
end
