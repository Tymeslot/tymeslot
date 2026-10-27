defmodule Tymeslot.Integrations.Shared.OAuthConfigTest do
  # async: false: application config and environment variables are global.
  use ExUnit.Case, async: false

  @moduletag :integrations

  alias Tymeslot.Integrations.Shared.OAuthConfig

  setup do
    prior_config = Application.fetch_env(:tymeslot, :zoom_oauth)
    prior_env = System.get_env("ZOOM_CLIENT_ID")
    Application.delete_env(:tymeslot, :zoom_oauth)
    System.delete_env("ZOOM_CLIENT_ID")

    on_exit(fn ->
      case prior_config do
        {:ok, value} -> Application.put_env(:tymeslot, :zoom_oauth, value)
        :error -> Application.delete_env(:tymeslot, :zoom_oauth)
      end

      if prior_env,
        do: System.put_env("ZOOM_CLIENT_ID", prior_env),
        else: System.delete_env("ZOOM_CLIENT_ID")
    end)
  end

  test "reads the application config first" do
    Application.put_env(:tymeslot, :zoom_oauth, client_id: "from-config")
    System.put_env("ZOOM_CLIENT_ID", "from-env")

    assert OAuthConfig.fetch(:zoom, :client_id) == {:ok, "from-config"}
  end

  test "falls back to the environment variable" do
    System.put_env("ZOOM_CLIENT_ID", "from-env")

    assert OAuthConfig.fetch(:zoom, :client_id) == {:ok, "from-env"}
  end

  test "treats a blank value as unset, falling through to the next source" do
    Application.put_env(:tymeslot, :zoom_oauth, client_id: "  ")
    System.put_env("ZOOM_CLIENT_ID", "from-env")

    assert OAuthConfig.fetch(:zoom, :client_id) == {:ok, "from-env"}
  end

  test "reports a value blank everywhere as not configured" do
    System.put_env("ZOOM_CLIENT_ID", "")

    assert OAuthConfig.get(:zoom, :client_id) == nil
    assert OAuthConfig.fetch(:zoom, :client_id) == {:error, "Zoom Client ID not configured"}

    assert_raise RuntimeError, "Zoom Client ID not configured", fn ->
      OAuthConfig.fetch!(:zoom, :client_id)
    end
  end

  test "names Microsoft's variables by their Outlook names" do
    assert OAuthConfig.env_var(:microsoft, :state_secret) == "OUTLOOK_STATE_SECRET"
    assert OAuthConfig.env_var(:google, :client_secret) == "GOOGLE_CLIENT_SECRET"
  end

  describe "setup_error_message/3" do
    test "names every variable a flow needs when its state secret is missing" do
      error = %RuntimeError{message: "Google State Secret not configured"}

      assert OAuthConfig.setup_error_message(:google, "Google", error) ==
               "Google OAuth is not configured. Please set GOOGLE_CLIENT_ID, " <>
                 "GOOGLE_CLIENT_SECRET, and GOOGLE_STATE_SECRET environment variables."
    end

    test "names the one missing variable, by the provider's own prefix" do
      error = %RuntimeError{message: "Microsoft Client ID not configured"}

      assert OAuthConfig.setup_error_message(:microsoft, "Outlook", error) ==
               "Outlook OAuth is not configured. Please set OUTLOOK_CLIENT_ID environment variable."
    end

    test "passes any other failure through" do
      error = %RuntimeError{message: "Something went wrong"}

      assert OAuthConfig.setup_error_message(:zoom, "Zoom", error) ==
               "Failed to setup Zoom OAuth: Something went wrong"
    end
  end

  describe "blank_state_secrets/1" do
    test "names the state secrets that are set but blank, and no others" do
      env = %{
        "GOOGLE_STATE_SECRET" => "",
        "OUTLOOK_STATE_SECRET" => "s3cret",
        "ZOOM_STATE_SECRET" => "  "
      }

      assert Enum.sort(OAuthConfig.blank_state_secrets(env)) ==
               ["GOOGLE_STATE_SECRET", "ZOOM_STATE_SECRET"]

      assert OAuthConfig.blank_state_secrets(%{}) == []
    end
  end
end
