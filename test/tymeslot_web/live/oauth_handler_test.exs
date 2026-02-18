defmodule TymeslotWeb.Live.OAuthHandlerTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Live.OAuthHandler

  describe "handle_oauth_redirect/3" do
  @moduletag :utils
    test "sends message and closes modal for OAuth provider" do
      socket = %Socket{assigns: %{__changed__: %{}, show_provider_modal: true}}
      # IntegrationProviders.oauth_provider? is used here.
      # "google" + :calendar is an OAuth provider.

      updated = OAuthHandler.handle_oauth_redirect(socket, "google", :calendar)
      assert updated.assigns.show_provider_modal == false
      assert_receive {:oauth_redirect, "google", :calendar}
    end

    test "just closes modal for non-OAuth provider" do
      socket = %Socket{assigns: %{__changed__: %{}, show_provider_modal: true}}
      updated = OAuthHandler.handle_oauth_redirect(socket, "unknown", :calendar)
      assert updated.assigns.show_provider_modal == false
      refute_receive {:oauth_redirect, _, _}
    end
  end

  describe "handle_oauth_event/2" do
    test "returns correct redirect for known providers" do
      assert {:oauth_redirect, "google_calendar"} =
               OAuthHandler.handle_oauth_event("google", :calendar)

      assert {:oauth_redirect, "outlook_calendar"} =
               OAuthHandler.handle_oauth_event("outlook", :calendar)

      assert {:oauth_redirect, "google_meet"} =
               OAuthHandler.handle_oauth_event("google_meet", :video)

      assert {:oauth_redirect, "teams"} = OAuthHandler.handle_oauth_event("teams", :video)
    end

    test "returns error for unknown providers" do
      assert {:error, _reason} = OAuthHandler.handle_oauth_event("unknown", :calendar)
    end
  end

  describe "send_oauth_redirect/2" do
    test "sends message to self for valid provider" do
      assert :ok = OAuthHandler.send_oauth_redirect("google", :calendar)
      assert_receive {:oauth_redirect, "google_calendar"}
    end

    test "returns error for invalid provider" do
      assert {:error, _reason} = OAuthHandler.send_oauth_redirect("unknown", :calendar)
    end
  end
end
