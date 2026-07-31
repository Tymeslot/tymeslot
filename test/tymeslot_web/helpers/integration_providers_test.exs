defmodule TymeslotWeb.Helpers.IntegrationProvidersTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Helpers.IntegrationProviders

  describe "reason_to_form_errors/1" do
    test "blames :api_key on an :invalid_api_key tag" do
      assert %{api_key: "Invalid API key - Authentication failed"} =
               IntegrationProviders.reason_to_form_errors(
                 {:invalid_api_key, "Invalid API key - Authentication failed"}
               )
    end

    test "blames :base_url on an :unreachable tag" do
      assert %{base_url: "Domain not found - Please check the URL"} =
               IntegrationProviders.reason_to_form_errors(
                 {:unreachable, "Domain not found - Please check the URL"}
               )
    end

    # The tag decides the field, so a translated message must not move it.
    # This is the regression the English-substring classifier caused: the
    # localised text carries no keyword left to match on.
    test "keeps the field when the message is localised" do
      assert %{api_key: "Ungültiger API-Schlüssel"} =
               IntegrationProviders.reason_to_form_errors(
                 {:invalid_api_key, "Ungültiger API-Schlüssel"}
               )

      assert %{base_url: "Domain nicht gefunden"} =
               IntegrationProviders.reason_to_form_errors({:unreachable, "Domain nicht gefunden"})
    end

    test "falls back to base_url for an untagged message" do
      assert %{base_url: "Some weird error"} =
               IntegrationProviders.reason_to_form_errors("Some weird error")

      assert %{base_url: "Invalid API key"} =
               IntegrationProviders.reason_to_form_errors("Invalid API key")
    end

    test "falls back to base_url with generic copy for a non-binary reason" do
      assert %{base_url: "Connection validation failed"} =
               IntegrationProviders.reason_to_form_errors(nil)
    end
  end

  describe "connection_test_error_message/1" do
    test "renders the message from a tagged reason" do
      assert IntegrationProviders.connection_test_error_message(
               {:unreachable, "Connection refused - Server may be down or URL incorrect"}
             ) == "Connection refused - Server may be down or URL incorrect"
    end

    test "renders a bare message as-is" do
      assert IntegrationProviders.connection_test_error_message("Boom") == "Boom"
    end

    test "inspects an unrecognised reason" do
      assert IntegrationProviders.connection_test_error_message(:oops) ==
               "Connection test failed: :oops"
    end
  end
end
