defmodule Tymeslot.Integrations.Video.OAuthCallbackTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Video.OAuthCallback

  setup :verify_on_exit!

  # The state is the only thing binding a provider's code to a Tymeslot user,
  # so it is checked against the user completing the callback before the code
  # is spent. No HTTP expectation is set: any token request fails the test.
  describe "complete/4" do
    test "refuses a state issued to another user" do
      user = insert(:user)
      state = State.generate(insert(:user).id, "test-outlook-state-secret")

      assert {:error, :state_user_mismatch} =
               OAuthCallback.complete(:teams, "code", state, user.id)
    end

    test "refuses a malformed state" do
      assert {:error, _reason} =
               OAuthCallback.complete(:google_meet, "code", "bogus", insert(:user).id)
    end
  end
end
